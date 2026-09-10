// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { BaseOrderTest } from "../utils/BaseOrderTest.sol";

import {
    AdvancedOrder,
    CriteriaResolver,
    FulfillmentComponent,
    Schema,
    ZoneParameters
} from "seaport-types/src/lib/ConsiderationStructs.sol";

import { OrderType } from "seaport-types/src/lib/ConsiderationEnums.sol";
import { ZoneInterface } from "seaport-types/src/interfaces/ZoneInterface.sol";
import { ConsiderationInterface } from
    "seaport-types/src/interfaces/ConsiderationInterface.sol";
import { ERC165 } from "@openzeppelin/contracts/utils/introspection/ERC165.sol";

contract CountingZone is ERC165, ZoneInterface {
    uint256 public authorizeCount;
    uint256 public validateCount;

    function authorizeOrder(ZoneParameters calldata)
        public
        returns (bytes4)
    {
        ++authorizeCount;
        return ZoneInterface.authorizeOrder.selector;
    }

    function validateOrder(ZoneParameters calldata)
        external
        returns (bytes4)
    {
        ++validateCount;
        return ZoneInterface.validateOrder.selector;
    }

    function getSeaportMetadata()
        external
        pure
        override
        returns (string memory name, Schema[] memory schemas)
    {
        schemas = new Schema[](0);
        return ("CountingZone", schemas);
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC165, ZoneInterface)
        returns (bool)
    {
        return interfaceId == type(ZoneInterface).interfaceId
            || super.supportsInterface(interfaceId);
    }
}

contract AuthorizeStatusRollbackTest is BaseOrderTest {
    CountingZone internal zone;

    function setUp() public override {
        super.setUp();
        zone = new CountingZone();
    }

    function _buildDuplicateRestrictedOrders()
        internal
        returns (
            AdvancedOrder[] memory orders,
            CriteriaResolver[] memory criteriaResolvers,
            FulfillmentComponent[][] memory offerFulfillments,
            FulfillmentComponent[][] memory considerationFulfillments
        )
    {
        addErc20OfferItem(10);
        addErc20ConsiderationItem(payable(alice), 1);

        _configureOrderParameters({
            offerer: alice,
            zone: address(zone),
            zoneHash: bytes32(0),
            salt: 0xA11CE,
            useConduit: false
        });
        baseOrderParameters.orderType = OrderType.FULL_RESTRICTED;

        configureOrderComponents(consideration);
        bytes32 orderHash = consideration.getOrderHash(baseOrderComponents);
        bytes memory signature = signOrder(consideration, alicePk, orderHash);

        AdvancedOrder memory order = AdvancedOrder({
            parameters: baseOrderParameters,
            numerator: 1,
            denominator: 1,
            signature: signature,
            extraData: "stateful-zone"
        });

        orders = new AdvancedOrder[](2);
        orders[0] = order;
        orders[1] = order;

        criteriaResolvers = new CriteriaResolver[](0);
        offerFulfillments = new FulfillmentComponent[][](2);
        considerationFulfillments = new FulfillmentComponent[][](2);

        for (uint256 i; i < 2; ++i) {
            offerFulfillments[i] = new FulfillmentComponent[](1);
            offerFulfillments[i][0] = FulfillmentComponent({
                orderIndex: i,
                itemIndex: 0
            });

            considerationFulfillments[i] = new FulfillmentComponent[](1);
            considerationFulfillments[i][0] = FulfillmentComponent({
                orderIndex: i,
                itemIndex: 0
            });
        }
    }

    function _callDuplicateRestrictedOrders()
        internal
        returns (bool ok, bytes memory returndata)
    {
        (
            AdvancedOrder[] memory orders,
            CriteriaResolver[] memory criteriaResolvers,
            FulfillmentComponent[][] memory offerFulfillments,
            FulfillmentComponent[][] memory considerationFulfillments
        ) = _buildDuplicateRestrictedOrders();

        bytes memory payload = abi.encodeWithSelector(
            ConsiderationInterface.fulfillAvailableAdvancedOrders.selector,
            orders,
            criteriaResolvers,
            offerFulfillments,
            considerationFulfillments,
            bytes32(0),
            address(0),
            2
        );

        (ok, returndata) = address(consideration).call(payload);
    }

    function testCurrentPatchRevertsAndRollsBack() public {
        (bool ok, bytes memory returndata) = _callDuplicateRestrictedOrders();

        assertEq(ok, false, "duplicate restricted order must revert");
        assertEq(zone.authorizeCount(), 0, "authorize side effects survived");
        assertEq(zone.validateCount(), 0, "validate side effects survived");

        bytes4 actualSelector;
        if (returndata.length >= 4) {
            assembly {
                actualSelector := mload(add(returndata, 0x20))
            }
        }
        bytes4 expectedSelector =
            bytes4(keccak256("OrderAlreadyFilled(bytes32)"));
        assertEq(
            uint256(uint32(actualSelector)),
            uint256(uint32(expectedSelector)),
            "unexpected revert"
        );
    }

    function testVulnerableMutationLeavesUnpairedAuthorization() public {
        (bool ok,) = _callDuplicateRestrictedOrders();

        assertEq(ok, true, "vulnerable mutation should skip duplicate");
        assertEq(zone.authorizeCount(), 2, "both pre-hooks should persist");
        assertEq(zone.validateCount(), 1, "only fulfilled order is ratified");
    }
}
