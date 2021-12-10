// SPDX-License-Identifier: MIT
pragma solidity 0.8.10;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract catsluck4fun {
    address constant public erc20Address = 0xFE2de72a416F79058d682612a3af652Aa7d02555;

    uint constant private DIV = 10**18;

    uint private totalShare;
    mapping(address => uint) private sharesAndLockUntil;
    mapping(address => uint) public buyerTickets;

    event Buy(address indexed addr, uint data);
    event Win(address indexed addr, uint data);
    event Deposit(address indexed addr, uint data);
    event Withdraw(address indexed addr, uint data);

    function safeTransferFrom(address addr, uint amount) private returns (uint, uint) {
        uint oldBalance = IERC20(erc20Address).balanceOf(address(this));
        IERC20(erc20Address).transferFrom(addr, address(this), amount);
        uint newBalance = IERC20(erc20Address).balanceOf(address(this));
        return (newBalance - oldBalance, oldBalance);
    }

    function deposit(uint amount, uint lockUntil) public {
        uint oldBalance;
        (amount, oldBalance) = safeTransferFrom(msg.sender, amount);
        uint mySharesAndLockUntil = sharesAndLockUntil[msg.sender];
        uint oldShare = mySharesAndLockUntil>>64;
        uint oldLockUntil = uint(uint64(mySharesAndLockUntil));
        uint oneHourLater = block.timestamp + 3600;
        if(lockUntil < oneHourLater) lockUntil = oneHourLater;
        if(oldShare > 0) {
            require(lockUntil >= oldLockUntil, "invalid lockUntil");
        }
        if(totalShare == 0) {
            emit Deposit(msg.sender, amount<<(96+64) | (amount<<64) | block.timestamp);
            sharesAndLockUntil[msg.sender] = (amount<<64) | lockUntil;
            totalShare = amount;
            return;
        }
        // deltaShare / totalShare = amount / oldBalance
        uint deltaShare = amount * totalShare / oldBalance;
        sharesAndLockUntil[msg.sender] = ((deltaShare+oldShare)<<64) | lockUntil;
        totalShare += deltaShare;
        emit Deposit(msg.sender, amount<<(96+64) | (deltaShare<<64) | block.timestamp);
    }

    function info(address addr) external view returns (uint, uint, uint) {
        uint totalBalance = IERC20(erc20Address).balanceOf(address(this));
        return (totalBalance, totalShare, sharesAndLockUntil[addr]);
    }

    function withdraw(uint deltaShare) external {
        uint mySharesAndLockUntil = sharesAndLockUntil[msg.sender];
        uint oldShare = mySharesAndLockUntil>>64;
        uint lockUntil = uint(uint64(mySharesAndLockUntil));
        require(oldShare >= deltaShare, "not enough share");
        require(block.timestamp > lockUntil, "still locked");
        uint oldBalance = IERC20(erc20Address).balanceOf(address(this));
        // deltaBalance / oldBalance = deltaShare / totalShare
        uint deltaBalance = oldBalance * deltaShare / totalShare;
        sharesAndLockUntil[msg.sender] = ((oldShare - deltaShare)<<64) | lockUntil;
        totalShare -= deltaShare;
        IERC20(erc20Address).transfer(msg.sender, deltaBalance);
        emit Withdraw(msg.sender, deltaBalance<<(96+64) | (deltaShare<<64) | block.timestamp);
    }

    function buyLottery(uint amount, uint multiplierX100) external {
        uint amountAndHeightAndMul = buyerTickets[msg.sender];
        if(amountAndHeightAndMul != 0) {
            uint height = uint(uint64(amountAndHeightAndMul>>32));
            // There may be some pending reward
            if(height + 256 > block.number && blockhash(height) != 0) {
                getMyReward();
            }
        }
        uint oldBalance;
        (amount, oldBalance) = safeTransferFrom(msg.sender, amount);
        uint fee = amount / 40; // totally 2.5% fee
        uint remainedAmount = amount - fee;
        require(105 <= multiplierX100 && multiplierX100 <= 100000, "invalid multiplier");
	if(multiplierX100 > 300) {
            // remainedAmount*(multiplierX100/100) < oldBalance*0.01
            require(remainedAmount*multiplierX100 < oldBalance, "amount too large");
	} else {
            // remainedAmount*(multiplierX100/100) < oldBalance*0.005
            require(remainedAmount*multiplierX100*2 < oldBalance, "amount too large");
	}

        buyerTickets[msg.sender] = (remainedAmount<<96) | (block.number<<32) | multiplierX100;
        emit Buy(msg.sender, (amount<<(64+32)) | (multiplierX100<<64) | block.timestamp);
    }

    function getMyReward() public returns (uint) {
        uint amountAndHeightAndMul = buyerTickets[msg.sender];
        if(amountAndHeightAndMul == 0) return 0;
        uint multiplierX100 = uint(uint32(amountAndHeightAndMul));
        uint height = uint(uint64(amountAndHeightAndMul>>32));
        uint amount = amountAndHeightAndMul>>96;
        bytes32 hash = blockhash(height);
        if(uint(hash) == 0) return ~uint(0); // a value with all ones
        delete buyerTickets[msg.sender]; //to prevent replay

        uint rand = uint(keccak256(abi.encodePacked(hash, amountAndHeightAndMul, msg.sender)));
        uint reward = 0;
        rand = rand % DIV;
        // rand / DIV <= 100 / multiplierX100
        bool isLucky = rand*multiplierX100 < DIV*100;
        if(isLucky) {
            reward = amount*multiplierX100/100;
            IERC20(erc20Address).transfer(msg.sender, reward);
            emit Win(msg.sender, (reward<<(64+32)) | (multiplierX100<<64) | block.timestamp);
        }
        return reward;
    }
}
