// OnionCoin.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "contracts/mainfunc.sol";

contract OnionCoin is mainfunc {
    event InitialSupplyMinted(address indexed to, uint256 amount);

    constructor(uint256 initialSupply) mainfunc("OnionCoin", "ONC",address(this),address(0xeE567Fe1712Faf6149d80dA1E6934E354124CfE3)){
        uint256 total = initialSupply * 1e18;
        require(total <= MAX_SUPPLY,"total > MAX_SUPPLY");  
        _mint(msg.sender, total / 2);

        _mint(address(this), total / 2);
        
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(MINTER_ROLE, msg.sender);
        _grantRole(PAUSER_ROLE, msg.sender);
        _grantRole(BURNER_ROLE, msg.sender);
        emit InitialSupplyMinted(msg.sender, total/2);
        emit InitialSupplyMinted(address(this), total/2);
    }
}

