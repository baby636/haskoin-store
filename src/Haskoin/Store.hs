{-# LANGUAGE ConstraintKinds       #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE GADTs                 #-}
{-# LANGUAGE LambdaCase            #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE MultiWayIf            #-}
{-# LANGUAGE OverloadedStrings     #-}
module Haskoin.Store
    ( Store(..)
    , BlockStore
    , StoreConfig(..)
    , StoreEvent(..)
    , BlockData(..)
    , Transaction(..)
    , Input(..)
    , Output(..)
    , Spender(..)
    , BlockRef(..)
    , Unspent(..)
    , BlockTx(..)
    , XPubBal(..)
    , XPubUnspent(..)
    , Balance(..)
    , PeerInformation(..)
    , PreciseUnixTime(..)
    , HealthCheck(..)
    , PubExcept(..)
    , Event(..)
    , TxAfterHeight(..)
    , JsonSerial(..)
    , ProtoSerial(..)
    , withStore
    , store
    , getBestBlock
    , getBlocksAtHeight
    , getBlock
    , getTransaction
    , getTxData
    , getSpenders
    , getSpender
    , fromTransaction
    , toTransaction
    , getBalance
    , getMempool
    , getAddressUnspents
    , getAddressTxs
    , getPeersInformation
    , xpubTxs
    , xpubBals
    , xpubUnspent
    , publishTx
    , transactionData
    , isCoinbase
    , confirmed
    , blockDataToJSON
    , blockDataToEncoding
    , transactionToJSON
    , transactionToEncoding
    , outputToJSON
    , outputToEncoding
    , inputToJSON
    , inputToEncoding
    , unspentToJSON
    , unspentToEncoding
    , balanceToJSON
    , balanceToEncoding
    , xPubBalToJSON
    , xPubBalToEncoding
    , xPubUnspentToJSON
    , xPubUnspentToEncoding
    , cbAfterHeight
    , healthCheck
    , mergeSourcesBy
    ) where

import           Conduit
import           Control.Monad.Except           as E
import           Control.Monad.Logger
import           Control.Monad.Trans.Maybe
import           Data.Foldable
import           Data.Function
import           Data.List
import           Data.Maybe
import           Data.Serialize                 (decode)
import           Database.RocksDB               as R
import           Haskoin
import           Haskoin.Node
import           Network.Haskoin.Store.Block
import           Network.Haskoin.Store.Data
import           Network.Haskoin.Store.Messages
import           Network.Haskoin.Store.Proto
import           Network.Socket                 (SockAddr (..))
import           NQE
import           System.Random
import           UnliftIO

data PubExcept
    = PubNoPeers
    | PubReject RejectCode
    | PubTimeout
    | PubNotFound
    | PubPeerDisconnected
    deriving Eq

instance Show PubExcept where
    show PubNoPeers = "no peers"
    show (PubReject c) =
        "rejected: " <>
        case c of
            RejectMalformed       -> "malformed"
            RejectInvalid         -> "invalid"
            RejectObsolete        -> "obsolete"
            RejectDuplicate       -> "duplicate"
            RejectNonStandard     -> "not standard"
            RejectDust            -> "dust"
            RejectInsufficientFee -> "insufficient fee"
            RejectCheckpoint      -> "checkpoint"
    show PubTimeout = "timeout"
    show PubNotFound = "not found"
    show PubPeerDisconnected = "peer disconnected"

instance Exception PubExcept

withStore ::
       (MonadLoggerIO m, MonadUnliftIO m)
    => StoreConfig
    -> (Store -> m a)
    -> m a
withStore cfg f = do
    mgri <- newInbox
    chi <- newInbox
    withProcess (store cfg mgri chi) $ \(Process a b) -> do
        link a
        f
            Store
                { storeManager = inboxToMailbox mgri
                , storeChain = inboxToMailbox chi
                , storeBlock = b
                }

-- | Run a Haskoin Store instance. It will launch a network node and a
-- 'BlockStore', connect to the network and start synchronizing blocks and
-- transactions.
store ::
       (MonadLoggerIO m, MonadUnliftIO m)
    => StoreConfig
    -> Inbox ManagerMessage
    -> Inbox ChainMessage
    -> Inbox BlockMessage
    -> m ()
store cfg mgri chi bsi = do
    let ncfg =
            NodeConfig
                { nodeConfMaxPeers = storeConfMaxPeers cfg
                , nodeConfDB = storeConfDB cfg
                , nodeConfPeers = storeConfInitPeers cfg
                , nodeConfDiscover = storeConfDiscover cfg
                , nodeConfEvents = storeDispatch b l
                , nodeConfNetAddr = NetworkAddress 0 (SockAddrInet 0 0)
                , nodeConfNet = storeConfNetwork cfg
                , nodeConfTimeout = 10
                }
    withAsync (node ncfg mgri chi) $ \a -> do
        link a
        let bcfg =
                BlockConfig
                    { blockConfChain = inboxToMailbox chi
                    , blockConfManager = inboxToMailbox mgri
                    , blockConfListener = l
                    , blockConfDB = storeConfDB cfg
                    , blockConfNet = storeConfNetwork cfg
                    }
        blockStore bcfg bsi
  where
    l = storeConfListen cfg
    b = inboxToMailbox bsi

-- | Dispatcher of node events.
storeDispatch :: BlockStore -> Listen StoreEvent -> Listen NodeEvent

storeDispatch b pub (PeerEvent (PeerConnected p a)) = do
    pub (StorePeerConnected p a)
    BlockPeerConnect p a `sendSTM` b

storeDispatch b pub (PeerEvent (PeerDisconnected p a)) = do
    pub (StorePeerDisconnected p a)
    BlockPeerDisconnect p a `sendSTM` b

storeDispatch b _ (ChainEvent (ChainBestBlock bn)) =
    BlockNewBest bn `sendSTM` b

storeDispatch _ _ (ChainEvent _) = return ()

storeDispatch _ pub (PeerEvent (PeerMessage p (MPong (Pong n)))) =
    pub (StorePeerPong p n)

storeDispatch b _ (PeerEvent (PeerMessage p (MBlock block))) =
    BlockReceived p block `sendSTM` b

storeDispatch b _ (PeerEvent (PeerMessage p (MTx tx))) =
    BlockTxReceived p tx `sendSTM` b

storeDispatch b _ (PeerEvent (PeerMessage p (MNotFound (NotFound is)))) = do
    let blocks =
            [ BlockHash h
            | InvVector t h <- is
            , t == InvBlock || t == InvWitnessBlock
            ]
    unless (null blocks) $ BlockNotFound p blocks `sendSTM` b

storeDispatch b pub (PeerEvent (PeerMessage p (MInv (Inv is)))) = do
    let txs = [TxHash h | InvVector t h <- is, t == InvTx || t == InvWitnessTx]
    pub (StoreTxAvailable p txs)
    unless (null txs) $ BlockTxAvailable p txs `sendSTM` b

storeDispatch _ pub (PeerEvent (PeerMessage p (MReject r))) =
    when (rejectMessage r == MCTx) $
    case decode (rejectData r) of
        Left _ -> return ()
        Right th ->
            pub $
            StoreTxReject p th (rejectCode r) (getVarString (rejectReason r))

storeDispatch _ _ (PeerEvent _) = return ()

healthCheck ::
       (MonadUnliftIO m, StoreRead r m)
    => Network
    -> r
    -> Manager
    -> Chain
    -> m HealthCheck
healthCheck net i mgr ch = do
    n <- timeout (5 * 1000 * 1000) $ chainGetBest ch
    b <-
        runMaybeT $ do
            h <- MaybeT $ getBestBlock i
            MaybeT $ getBlock i h
    p <- timeout (5 * 1000 * 1000) $ managerGetPeers mgr
    let k = isNothing n || isNothing b || maybe False (not . null) p
        s =
            isJust $ do
                x <- n
                y <- b
                guard $ nodeHeight x - blockDataHeight y <= 1
    return
        HealthCheck
            { healthBlockBest = headerHash . blockDataHeader <$> b
            , healthBlockHeight = blockDataHeight <$> b
            , healthHeaderBest = headerHash . nodeHeader <$> n
            , healthHeaderHeight = nodeHeight <$> n
            , healthPeers = length <$> p
            , healthNetwork = getNetworkName net
            , healthOK = k
            , healthSynced = s
            }

-- | Publish a new transaction to the network.
publishTx ::
       (MonadUnliftIO m, MonadLoggerIO m)
    => Publisher StoreEvent
    -> Store
    -> DB
    -> Tx
    -> m (Either PubExcept ())
publishTx pub st db tx =
    withSubscription pub $ \s -> do
        let d = (db, defaultReadOptions)
        getTransaction d (txHash tx) >>= \case
            Just _ -> return $ Right ()
            Nothing ->
                runExceptT $
                managerGetPeers (storeManager st) >>= \case
                    [] -> throwError PubNoPeers
                    OnlinePeer {onlinePeerMailbox = p}:_ -> do
                        MTx tx `sendMessage` p
                        MMempool `sendMessage` p
                        f p s
  where
    t = 15 * 1000 * 1000
    f p s = do
        n <- liftIO randomIO
        MPing (Ping n) `sendMessage` p
        liftIO (timeout t (runExceptT (g p s n))) >>= \case
            Nothing -> throwError PubTimeout
            Just e -> E.liftEither e
    g p s n =
        receive s >>= \case
            StoreTxReject p' h' c _
                | p == p' && h' == txHash tx -> throwError $ PubReject c
            StorePeerDisconnected p' _
                | p == p' -> throwError PubPeerDisconnected
            StoreMempoolNew h'
                | h' == txHash tx -> return ()
            _ -> g p s n

-- | Obtain information about connected peers from peer manager process.
getPeersInformation :: MonadIO m => Manager -> m [PeerInformation]
getPeersInformation mgr = mapMaybe toInfo <$> managerGetPeers mgr
  where
    toInfo op = do
        ver <- onlinePeerVersion op
        let as = onlinePeerAddress op
            ua = getVarString $ userAgent ver
            vs = version ver
            sv = services ver
            rl = relay ver
        return
            PeerInformation
                { peerUserAgent = ua
                , peerAddress = as
                , peerVersion = vs
                , peerServices = sv
                , peerRelay = rl
                }

xpubBals :: (Monad m, BalanceRead i m) => i -> XPubKey -> m [XPubBal]
xpubBals i xpub = (<>) <$> go 0 0 <*> go 1 0
  where
    g = getBalance i
    go m n = do
        xs <- catMaybes <$> mapM (uncurry b) (as m n)
        case xs of
            [] -> return []
            _  -> (xs <>) <$> go m (n + 20)
    b a p =
        g a >>= \case
            Nothing -> return Nothing
            Just b' -> return $ Just XPubBal {xPubBalPath = p, xPubBal = b'}
    as m n =
        map
            (\(a, _, n') -> (a, [m, n']))
            (take 20 (deriveAddrs (pubSubKey xpub m) n))

xpubTxs ::
       (Monad m, BalanceRead i m, StoreStream i m)
    => i
    -> Maybe BlockRef
    -> XPubKey
    -> ConduitT () BlockTx m ()
xpubTxs i mbr xpub = do
    bals <- lift $ xpubBals i xpub
    xs <-
        forM bals $ \XPubBal {xPubBal = b} ->
            return $ getAddressTxs i (balanceAddress b) mbr
    mergeSourcesBy (flip compare `on` blockTxBlock) xs

xpubUnspent ::
       (Monad m, StoreStream i m, BalanceRead i m, StoreRead i m)
    => i
    -> Maybe BlockRef
    -> XPubKey
    -> ConduitT () XPubUnspent m ()
xpubUnspent i mbr xpub = do
    bals <- lift $ xpubBals i xpub
    xs <-
        forM bals $ \XPubBal {xPubBalPath = p, xPubBal = b} ->
            return $ getAddressUnspents i (balanceAddress b) mbr .| mapC (f p)
    mergeSourcesBy (flip compare `on` (unspentBlock . xPubUnspent)) xs
  where
    f p t = XPubUnspent {xPubUnspentPath = p, xPubUnspent = t}

-- | Check if any of the ancestors of this transaction is a coinbase after the
-- specified height. Returns 'Nothing' if answer cannot be computed before
-- hitting limits.
cbAfterHeight ::
       (Monad m, StoreRead i m)
    => i
    -> Int -- ^ how many ancestors to test before giving up
    -> BlockHeight
    -> TxHash
    -> m TxAfterHeight
cbAfterHeight i d h t
    | d <= 0 = return $ TxAfterHeight Nothing
    | otherwise = TxAfterHeight <$> runMaybeT (snd <$> tst d t)
  where
    tst e x
        | e <= 0 = MaybeT $ return Nothing
        | otherwise = do
            let e' = e - 1
            tx <- MaybeT $ getTransaction i x
            if any isCoinbase (transactionInputs tx)
                then return (e', blockRefHeight (transactionBlock tx) > h)
                else case transactionBlock tx of
                         BlockRef {blockRefHeight = b}
                             | b <= h -> return (e', False)
                         _ ->
                             r e' . nub $
                             map
                                 (outPointHash . inputPoint)
                                 (transactionInputs tx)
    r e [] = return (e, False)
    r e (n:ns) = do
        (e', s) <- tst e n
        if s
            then return (e', True)
            else r e' ns

-- Snatched from:
-- https://github.com/cblp/conduit-merge/blob/master/src/Data/Conduit/Merge.hs
mergeSourcesBy ::
       (Foldable f, Monad m)
    => (a -> a -> Ordering)
    -> f (ConduitT () a m ())
    -> ConduitT i a m ()
mergeSourcesBy f = mergeSealed . fmap sealConduitT . toList
  where
    mergeSealed sources = do
        prefetchedSources <- lift $ traverse ($$++ await) sources
        go [(a, s) | (s, Just a) <- prefetchedSources]
    go [] = pure ()
    go sources = do
        let (a, src1):sources1 = sortBy (f `on` fst) sources
        yield a
        (src2, mb) <- lift $ src1 $$++ await
        let sources2 =
                case mb of
                    Nothing -> sources1
                    Just b  -> (b, src2) : sources1
        go sources2
