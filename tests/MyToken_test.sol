// OnionCoin.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "contracts/mainfunc.sol";

contract OnionCoion is mainfunc {

    constructor(uint256 initialSupply) mainfunc("OnionCoin", "ONC") {

        uint256 total = initialSupply * 10 ** decimals();

        _mint(msg.sender, total / 2);

        _mint(address(this), total / 2);

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(MINTER_ROLE, msg.sender);
        _grantRole(PAUSER_ROLE, msg.sender);
        _grantRole(BURNER_ROLE, msg.sender);
    }
}

