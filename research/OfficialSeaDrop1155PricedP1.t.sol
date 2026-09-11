// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ConsiderationInterface} from
    "seaport-types/src/interfaces/ConsiderationInterface.sol";
import {ConduitControllerInterface} from
    "seaport-types/src/interfaces/ConduitControllerInterface.sol";
import {ItemType, OrderType} from
    "seaport-types/src/lib/ConsiderationEnums.sol";
import {
    AdvancedOrder,
    ConsiderationItem,
    CriteriaResolver,
    Execution,
    Fulfillment,
    FulfillmentComponent,
    OfferItem,
    Order,
    OrderComponents,
    OrderParameters
} from "seaport-types/src/lib/ConsiderationStructs.sol";

interface IERC1155SeaDropCloneFactoryP1 {
    function createClone(
        string calldata name,
        string calldata symbol,
        bytes32 salt
    ) external returns (address instance);

    function seaport() external view returns (address);
    function configurer() external view returns (address);
    function cloneableImplementation() external view returns (address);
}

struct PublicDropP1 {
    uint80 startPrice;
    uint80 endPrice;
    uint40 startTime;
    uint40 endTime;
    bool restrictFeeRecipients;
    address paymentToken;
    uint24 fromTokenId;
    uint24 toTokenId;
    uint16 maxTotalMintableByWallet;
    uint16 maxTotalMintableByWalletPerToken;
    uint16 feeBps;
}

struct CreatorPayoutP1 {
    address payoutAddress;
    uint16 basisPoints;
}

interface IERC1155SeaDropP1 {
    function owner() external view returns (address);
    function configurer() external view returns (address);
    function getAllowedSeaport() external view returns (address[] memory);
    function setMaxSupply(uint256 tokenId, uint256 maxSupply) external;
    function updatePublicDrop(
        PublicDropP1 calldata publicDrop,
        uint256 index
    ) external;
    function updateCreatorPayouts(
        CreatorPayoutP1[] calldata creatorPayouts
    ) external;
    function updatePayer(address payer, bool allowed) external;
    function balanceOf(address account, uint256 id)
        external
        view
        returns (uint256);
    function safeTransferFrom(
        address from,
        address to,
        uint256 id,
        uint256 amount,
        bytes calldata data
    ) external;
}

interface IWETH9P1 {
    function deposit() external payable;
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function allowance(address owner, address spender)
        external
        view
        returns (uint256);
}

contract OfficialSeaDrop1155PricedP1Test is Test {
    address internal constant SEAPORT =
        0x0000000000000068F116a894984e2DB1123eB395;
    address internal constant CONDUIT_CONTROLLER =
        0x00000000F9490004C11Cef243f5400493c00Ad63;
    address internal constant OPENSEA_CONDUIT =
        0x1E0049783F008A0085193E00003D00cd54003c71;
    address internal constant FACTORY =
        0x00b19A5200A100e5fc4c9800772f4d002f218400;
    address internal constant OPTIMISM_WETH =
        0x4200000000000000000000000000000000000006;

    bytes32 internal constant OPENSEA_CONDUIT_KEY =
        0x0000007b02230091a7ed01230072f7006a004d60a8d4e71d599b8104250f0000;

    uint256 internal constant TOKEN_ID = 9_001;
    uint256 internal constant PRICE = 0.1 ether;
    uint256 internal constant BUYER_KEY =
        0xB0B0000000000000000000000000000000000000000000000000000000000001;
    uint256 internal constant BUYER2_KEY =
        0xB0B0000000000000000000000000000000000000000000000000000000000002;
    uint256 internal constant BUYER3_KEY =
        0xB0B0000000000000000000000000000000000000000000000000000000000003;

    ConsiderationInterface internal seaport;
    IERC1155SeaDropCloneFactoryP1 internal factory;
    IERC1155SeaDropP1 internal collection;
    IWETH9P1 internal weth;

    address internal collectionOwner = address(0xC011EC7100);
    address internal attacker = address(0xA77AC0);
    address internal buyer;
    address internal clone;

    event AuthorizationDelta(
        address indexed buyer,
        uint256 signedPayment,
        uint256 actualPayment,
        uint256 signedTokenReceipt,
        uint256 actualTokenReceipt,
        address actualTokenHolder
    );

    function setUp() public {
        string memory rpc = vm.envString("OPTIMISM_RPC_URL");
        uint256 forkBlock = vm.envUint("OPTIMISM_FORK_BLOCK");
        vm.createSelectFork(rpc, forkBlock);

        assertEq(block.chainid, 10, "wrong chain");
        assertEq(block.number, forkBlock, "wrong block");
        assertEq(SEAPORT.code.length, 23_981, "wrong Seaport runtime");
        assertGt(CONDUIT_CONTROLLER.code.length, 0, "controller missing");
        assertGt(OPENSEA_CONDUIT.code.length, 0, "conduit missing");
        assertGt(FACTORY.code.length, 0, "factory missing");
        assertGt(OPTIMISM_WETH.code.length, 0, "WETH missing");

        seaport = ConsiderationInterface(SEAPORT);
        factory = IERC1155SeaDropCloneFactoryP1(FACTORY);
        weth = IWETH9P1(OPTIMISM_WETH);
        buyer = vm.addr(BUYER_KEY);

        assertNotEq(attacker, buyer);
        assertNotEq(attacker, collectionOwner);
        assertNotEq(buyer, collectionOwner);

        (string memory version,, address controller) = seaport.information();
        assertEq(keccak256(bytes(version)), keccak256(bytes("1.6")));
        assertEq(controller, CONDUIT_CONTROLLER, "wrong controller");
        assertEq(factory.seaport(), SEAPORT, "factory not bound to Seaport 1.6");
        assertTrue(
            ConduitControllerInterface(CONDUIT_CONTROLLER).getChannelStatus(
                OPENSEA_CONDUIT,
                SEAPORT
            ),
            "Seaport conduit channel closed"
        );

        vm.prank(collectionOwner);
        clone = factory.createClone(
            "Official priced SeaDrop settlement lab",
            "OPSL",
            keccak256(abi.encode(address(this), forkBlock, TOKEN_ID))
        );
        collection = IERC1155SeaDropP1(clone);

        assertGt(clone.code.length, 0, "clone missing");
        assertEq(collection.owner(), collectionOwner, "wrong owner");
        address[] memory allowedSeaports = collection.getAllowedSeaport();
        assertEq(allowedSeaports.length, 1, "allowed Seaport length");
        assertEq(allowedSeaports[0], SEAPORT, "clone not bound to 1.6");

        CreatorPayoutP1[] memory payouts = new CreatorPayoutP1[](1);
        payouts[0] = CreatorPayoutP1({
            payoutAddress: collectionOwner,
            basisPoints: 10_000
        });
        PublicDropP1 memory drop = PublicDropP1({
            startPrice: uint80(PRICE),
            endPrice: uint80(PRICE),
            startTime: 0,
            endTime: type(uint40).max,
            restrictFeeRecipients: false,
            paymentToken: OPTIMISM_WETH,
            fromTokenId: uint24(TOKEN_ID),
            toTokenId: uint24(TOKEN_ID),
            maxTotalMintableByWallet: 100,
            maxTotalMintableByWalletPerToken: 100,
            feeBps: 0
        });

        vm.startPrank(collectionOwner);
        collection.setMaxSupply(TOKEN_ID, 100);
        collection.updateCreatorPayouts(payouts);
        collection.updatePublicDrop(drop, 0);
        collection.updatePayer(attacker, true);
        vm.stopPrank();

        _fundAndApproveBuyer(buyer, PRICE * 10);
    }

    function testSignedBuyerPaysCreatorWhileOutsiderKeepsExactERC1155()
        public
    {
        OrderParameters memory buyerParameters = _buyerParameters(
            buyer,
            PRICE,
            TOKEN_ID,
            1,
            0xC001
        );
        bytes32 buyerOrderHash = _orderHash(buyerParameters);
        bytes memory buyerSignature = _signBuyerOrder(
            buyerParameters,
            BUYER_KEY
        );

        uint256 buyerPaymentBefore = weth.balanceOf(buyer);
        uint256 creatorPaymentBefore = weth.balanceOf(collectionOwner);
        uint256 attackerPaymentBefore = weth.balanceOf(attacker);
        uint256 buyerNftBefore = collection.balanceOf(buyer, TOKEN_ID);
        uint256 attackerNftBefore = collection.balanceOf(attacker, TOKEN_ID);

        AdvancedOrder[] memory orders = new AdvancedOrder[](2);
        orders[0] = AdvancedOrder({
            parameters: buyerParameters,
            numerator: 1,
            denominator: 1,
            signature: buyerSignature,
            extraData: bytes("")
        });
        orders[1] = _contractOrder(
            TOKEN_ID,
            1,
            _publicMintContext(collectionOwner, address(0), 0)
        );

        Fulfillment[] memory fulfillments = new Fulfillment[](2);
        fulfillments[0] = _singleFulfillment(1, 0, 0, 0);
        fulfillments[1] = _singleFulfillment(0, 0, 1, 0);

        vm.prank(attacker);
        Execution[] memory executions = seaport.matchAdvancedOrders(
            orders,
            new CriteriaResolver[](0),
            fulfillments,
            attacker
        );
        assertGt(executions.length, 0, "no executions");

        assertEq(
            buyerPaymentBefore - weth.balanceOf(buyer),
            PRICE,
            "buyer did not pay exact signed price"
        );
        assertEq(
            weth.balanceOf(collectionOwner) - creatorPaymentBefore,
            PRICE,
            "creator did not receive mint price"
        );
        assertEq(
            weth.balanceOf(attacker),
            attackerPaymentBefore,
            "test relies on residual payment"
        );
        assertEq(
            collection.balanceOf(buyer, TOKEN_ID) - buyerNftBefore,
            0,
            "buyer unexpectedly received token"
        );
        assertEq(
            collection.balanceOf(attacker, TOKEN_ID) - attackerNftBefore,
            1,
            "attacker did not retain mint"
        );
        assertEq(
            weth.allowance(buyer, SEAPORT),
            0,
            "direct Seaport approval unexpectedly used"
        );

        _assertFullFill(buyerOrderHash);
        emit AuthorizationDelta(buyer, PRICE, PRICE, 1, 0, attacker);
    }

    function testOneOutsiderAtomicallySettlesThreeBuyersWithoutDelivery()
        public
    {
        uint256[3] memory keys = [BUYER_KEY, BUYER2_KEY, BUYER3_KEY];
        address[3] memory buyers;
        OrderParameters[3] memory parameters;
        bytes32[3] memory hashes;

        for (uint256 i = 0; i < 3; ++i) {
            buyers[i] = vm.addr(keys[i]);
            if (i != 0) _fundAndApproveBuyer(buyers[i], PRICE * 2);
            parameters[i] = _buyerParameters(
                buyers[i],
                PRICE,
                TOKEN_ID,
                1,
                0xD000 + i
            );
            hashes[i] = _orderHash(parameters[i]);
        }

        uint256 creatorBefore = weth.balanceOf(collectionOwner);
        uint256 attackerNftBefore = collection.balanceOf(attacker, TOKEN_ID);
        uint256 attackerWethBefore = weth.balanceOf(attacker);

        AdvancedOrder[] memory orders = new AdvancedOrder[](4);
        for (uint256 i = 0; i < 3; ++i) {
            orders[i] = AdvancedOrder({
                parameters: parameters[i],
                numerator: 1,
                denominator: 1,
                signature: _signBuyerOrder(parameters[i], keys[i]),
                extraData: bytes("")
            });
        }
        orders[3] = _contractOrder(
            TOKEN_ID,
            3,
            _publicMintContext(collectionOwner, address(0), 0)
        );

        Fulfillment[] memory fulfillments = new Fulfillment[](2);
        FulfillmentComponent[] memory nftOffer =
            new FulfillmentComponent[](1);
        nftOffer[0] = FulfillmentComponent({orderIndex: 3, itemIndex: 0});
        FulfillmentComponent[] memory nftConsideration =
            new FulfillmentComponent[](3);
        FulfillmentComponent[] memory paymentOffers =
            new FulfillmentComponent[](3);
        for (uint256 i = 0; i < 3; ++i) {
            nftConsideration[i] = FulfillmentComponent({
                orderIndex: i,
                itemIndex: 0
            });
            paymentOffers[i] = FulfillmentComponent({
                orderIndex: i,
                itemIndex: 0
            });
        }
        fulfillments[0] = Fulfillment({
            offerComponents: nftOffer,
            considerationComponents: nftConsideration
        });
        FulfillmentComponent[] memory mintPayment =
            new FulfillmentComponent[](1);
        mintPayment[0] = FulfillmentComponent({orderIndex: 3, itemIndex: 0});
        fulfillments[1] = Fulfillment({
            offerComponents: paymentOffers,
            considerationComponents: mintPayment
        });

        vm.prank(attacker);
        seaport.matchAdvancedOrders(
            orders,
            new CriteriaResolver[](0),
            fulfillments,
            attacker
        );

        for (uint256 i = 0; i < 3; ++i) {
            assertEq(
                weth.balanceOf(buyers[i]),
                i == 0 ? PRICE * 9 : PRICE,
                "buyer payment"
            );
            assertEq(
                collection.balanceOf(buyers[i], TOKEN_ID),
                0,
                "buyer received token"
            );
            _assertFullFill(hashes[i]);
        }
        assertEq(
            weth.balanceOf(collectionOwner) - creatorBefore,
            PRICE * 3,
            "creator aggregate payment"
        );
        assertEq(
            collection.balanceOf(attacker, TOKEN_ID) - attackerNftBefore,
            3,
            "attacker aggregate mint"
        );
        assertEq(
            weth.balanceOf(attacker),
            attackerWethBefore,
            "fanout relies on residual"
        );
    }

    function testExplicitBuyerMinterDeliversCanonicalSettlement() public {
        OrderParameters memory buyerParameters = _buyerParameters(
            buyer,
            PRICE,
            TOKEN_ID,
            1,
            0xC002
        );
        AdvancedOrder[] memory orders = new AdvancedOrder[](2);
        orders[0] = AdvancedOrder({
            parameters: buyerParameters,
            numerator: 1,
            denominator: 1,
            signature: _signBuyerOrder(buyerParameters, BUYER_KEY),
            extraData: bytes("")
        });
        orders[1] = _contractOrder(
            TOKEN_ID,
            1,
            _publicMintContext(collectionOwner, buyer, 0)
        );
        Fulfillment[] memory fulfillments = new Fulfillment[](2);
        fulfillments[0] = _singleFulfillment(1, 0, 0, 0);
        fulfillments[1] = _singleFulfillment(0, 0, 1, 0);

        vm.prank(attacker);
        seaport.matchAdvancedOrders(
            orders,
            new CriteriaResolver[](0),
            fulfillments,
            attacker
        );

        assertEq(collection.balanceOf(buyer, TOKEN_ID), 1);
        assertEq(collection.balanceOf(attacker, TOKEN_ID), 0);
    }

    function testUnvalidatedUnsignedBuyerOrderCannotBeTaken() public {
        OrderParameters memory buyerParameters = _buyerParameters(
            buyer,
            PRICE,
            TOKEN_ID,
            1,
            0xC003
        );
        AdvancedOrder[] memory orders = new AdvancedOrder[](2);
        orders[0] = AdvancedOrder({
            parameters: buyerParameters,
            numerator: 1,
            denominator: 1,
            signature: bytes(""),
            extraData: bytes("")
        });
        orders[1] = _contractOrder(
            TOKEN_ID,
            1,
            _publicMintContext(collectionOwner, address(0), 0)
        );
        Fulfillment[] memory fulfillments = new Fulfillment[](2);
        fulfillments[0] = _singleFulfillment(1, 0, 0, 0);
        fulfillments[1] = _singleFulfillment(0, 0, 1, 0);

        uint256 buyerBefore = weth.balanceOf(buyer);
        vm.prank(attacker);
        vm.expectRevert();
        seaport.matchAdvancedOrders(
            orders,
            new CriteriaResolver[](0),
            fulfillments,
            attacker
        );
        assertEq(weth.balanceOf(buyer), buyerBefore);
        assertEq(collection.balanceOf(attacker, TOKEN_ID), 0);
    }

    function testOfficialSelfSourceTransferReportsSuccessWithoutMoving()
        public
    {
        uint256 buyerBefore = collection.balanceOf(buyer, TOKEN_ID);
        vm.prank(SEAPORT);
        collection.safeTransferFrom(
            clone,
            buyer,
            TOKEN_ID,
            1,
            bytes("")
        );
        assertEq(collection.balanceOf(buyer, TOKEN_ID), buyerBefore);
    }

    function _fundAndApproveBuyer(address account, uint256 amount) internal {
        vm.deal(account, amount);
        vm.startPrank(account);
        weth.deposit{value: amount}();
        assertTrue(weth.approve(OPENSEA_CONDUIT, type(uint256).max));
        vm.stopPrank();
        assertEq(weth.allowance(account, SEAPORT), 0);
        assertEq(
            weth.allowance(account, OPENSEA_CONDUIT),
            type(uint256).max
        );
    }

    function _buyerParameters(
        address orderBuyer,
        uint256 price,
        uint256 tokenId,
        uint256 quantity,
        uint256 salt
    ) internal view returns (OrderParameters memory parameters) {
        OfferItem[] memory offer = new OfferItem[](1);
        offer[0] = OfferItem({
            itemType: ItemType.ERC20,
            token: OPTIMISM_WETH,
            identifierOrCriteria: 0,
            startAmount: price,
            endAmount: price
        });
        ConsiderationItem[] memory consideration = new ConsiderationItem[](1);
        consideration[0] = ConsiderationItem({
            itemType: ItemType.ERC1155,
            token: clone,
            identifierOrCriteria: tokenId,
            startAmount: quantity,
            endAmount: quantity,
            recipient: payable(orderBuyer)
        });
        parameters = OrderParameters({
            offerer: orderBuyer,
            zone: address(0),
            offer: offer,
            consideration: consideration,
            orderType: OrderType.FULL_OPEN,
            startTime: 0,
            endTime: type(uint256).max,
            zoneHash: bytes32(0),
            salt: salt,
            conduitKey: OPENSEA_CONDUIT_KEY,
            totalOriginalConsiderationItems: 1
        });
    }

    function _contractOrder(
        uint256 tokenId,
        uint256 quantity,
        bytes memory context
    ) internal view returns (AdvancedOrder memory order) {
        OfferItem[] memory offer = new OfferItem[](1);
        offer[0] = OfferItem({
            itemType: ItemType.ERC1155,
            token: clone,
            identifierOrCriteria: tokenId,
            startAmount: quantity,
            endAmount: quantity
        });
        ConsiderationItem[] memory consideration = new ConsiderationItem[](0);
        order = AdvancedOrder({
            parameters: OrderParameters({
                offerer: clone,
                zone: address(0),
                offer: offer,
                consideration: consideration,
                orderType: OrderType.CONTRACT,
                startTime: 0,
                endTime: type(uint256).max,
                zoneHash: bytes32(0),
                salt: 0,
                conduitKey: bytes32(0),
                totalOriginalConsiderationItems: 0
            }),
            numerator: 1,
            denominator: 1,
            signature: bytes(""),
            extraData: context
        });
    }

    function _publicMintContext(
        address feeRecipient,
        address minter,
        uint8 publicDropIndex
    ) internal pure returns (bytes memory) {
        return abi.encodePacked(
            bytes1(0x00),
            bytes1(0x00),
            bytes20(feeRecipient),
            bytes20(minter),
            bytes1(publicDropIndex)
        );
    }

    function _singleFulfillment(
        uint256 offerOrder,
        uint256 offerItem,
        uint256 considerationOrder,
        uint256 considerationItem
    ) internal pure returns (Fulfillment memory fulfillment) {
        FulfillmentComponent[] memory offers = new FulfillmentComponent[](1);
        offers[0] = FulfillmentComponent({
            orderIndex: offerOrder,
            itemIndex: offerItem
        });
        FulfillmentComponent[] memory considerations =
            new FulfillmentComponent[](1);
        considerations[0] = FulfillmentComponent({
            orderIndex: considerationOrder,
            itemIndex: considerationItem
        });
        fulfillment = Fulfillment({
            offerComponents: offers,
            considerationComponents: considerations
        });
    }

    function _orderHash(OrderParameters memory parameters)
        internal
        view
        returns (bytes32)
    {
        return seaport.getOrderHash(
            OrderComponents({
                offerer: parameters.offerer,
                zone: parameters.zone,
                offer: parameters.offer,
                consideration: parameters.consideration,
                orderType: parameters.orderType,
                startTime: parameters.startTime,
                endTime: parameters.endTime,
                zoneHash: parameters.zoneHash,
                salt: parameters.salt,
                conduitKey: parameters.conduitKey,
                counter: seaport.getCounter(parameters.offerer)
            })
        );
    }

    function _signBuyerOrder(
        OrderParameters memory parameters,
        uint256 key
    ) internal view returns (bytes memory signature) {
        bytes32 orderHash = _orderHash(parameters);
        (, bytes32 domainSeparator,) = seaport.information();
        bytes32 digest = keccak256(
            abi.encodePacked(bytes2(0x1901), domainSeparator, orderHash)
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        signature = abi.encodePacked(r, s, v);
    }

    function _assertFullFill(bytes32 orderHash) internal view {
        (
            bool validated,
            bool cancelled,
            uint256 filled,
            uint256 size
        ) = seaport.getOrderStatus(orderHash);
        assertTrue(validated, "not validated");
        assertFalse(cancelled, "cancelled");
        assertEq(filled, 1, "not fully filled");
        assertEq(size, 1, "wrong size");
    }
}
