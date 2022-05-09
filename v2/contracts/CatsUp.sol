// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract CatsUp is ERC20 {
    address public minter;

    constructor() ERC20("CatsUp", "CATSUP") {}

    function setMinter(address account) public {
        require(address(0) == minter, "already set");
        minter = account;
    }

    function mint(address account, uint256 amount) public {
        require(msg.sender == minter, "not minter");
        _mint(account, amount);
    }
}
