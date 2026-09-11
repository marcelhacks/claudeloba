// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {OfficialFactoryForkTest} from "./OfficialFactoryFork.t.sol";
import {
    AdvancedOrder,
    CriteriaResolver,
    Order
} from "./OfficialFactoryFork.t.sol";

contract OfficialFactorySignedForkTest is OfficialFactoryForkTest {
    function testStandardSignedFullOpenBidNeedsNoValidationTransaction() public {
        Order memory buyerOrder = _exactBuyerOrder(buyer, FIRST_ID, 0xE005);
        bytes32 orderHash = _hash(buyerOrder.parameters);
        (, bytes32 domainSeparator,) = seaport.information();
        bytes32 digest = keccak256(
            abi.encodePacked(bytes2(0x1901), domainSeparator, orderHash)
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(BUYER_KEY, digest);
        buyerOrder.signature = abi.encodePacked(r, s, v);

        AdvancedOrder[] memory advanced = new AdvancedOrder[](2);
        advanced[0] = AdvancedOrder(
            buyerOrder.parameters,
            1,
            1,
            buyerOrder.signature,
            bytes("")
        );
        advanced[1] = _seaDropOrder(_oneId(FIRST_ID), address(0));

        uint256 buyerWethBefore = weth.balanceOf(buyer);
        uint256 attackerWethBefore = weth.balanceOf(attacker);

        vm.prank(attacker);
        seaport.matchAdvancedOrders(
            advanced,
            new CriteriaResolver[](0),
            _singleFulfillment(1, 0, 0, 0),
            attacker
        );

        assertEq(weth.balanceOf(buyer), buyerWethBefore - PRICE);
        assertEq(weth.balanceOf(attacker), attackerWethBefore + PRICE);
        assertEq(IERC1155View(clone).balanceOf(buyer, FIRST_ID), 0);
        assertEq(IERC1155View(clone).balanceOf(attacker, FIRST_ID), 1);

        (bool validated, bool cancelled, uint256 filled, uint256 size) =
            seaport.getOrderStatus(orderHash);
        assertFalse(cancelled);
        assertEq(filled, 1);
        assertEq(size, 1);
        assertFalse(validated || cancelled && false);
    }
}
