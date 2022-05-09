// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./ERC20.sol";

interface Mintable {
    function mint(address account, uint256 amount) external;
}

interface VrfGovIfc {
    function verify(
        uint256 blockHash,
        uint256 rdm,
        bytes calldata pi
    ) external view returns (bool);
}

contract ClkLotteryPool is ERC20 {
    address private constant CatsupAddress =
        0xf8507984fe2B86941eAC7fB8FB4a5Fd39A019002;
    address private constant CatsAddress =
        0x265bD28d79400D55a1665707Fa14A72978FA6043;
    address private constant ClkAddress =
        0x659F04F36e90143fCaC202D4BC36C699C078fC98;
    address private constant VrfgovAddress =
        0x18C51aa3d1F018814716eC2c7C41A20d4FAf023C;
    address private constant BchAddress =
        0x0000000000000000000000000000000000002711;

    bytes4 private constant NAME = bytes4(keccak256(bytes("name()")));
    bytes4 private constant SYMBOL = bytes4(keccak256(bytes("symbol()")));
    bytes4 private constant DECIMALS = bytes4(keccak256(bytes("decimals()")));
    bytes4 private constant TRANSFER =
        bytes4(keccak256(bytes("transfer(address,uint256)")));

    uint256 private constant DIV = 10**18;
    address public immutable coin;

    uint192 private initPrice;
    uint8 private coinDecimals;

    uint256 public buybackPoolSize;
    uint192 public auctionPrice;
    uint64 public auctionStartTime;
    uint256[10] private gasTokens;

    mapping(address => uint256) public buyerTickets;

    uint256 public totalReferReward;
    mapping(address => uint256) public referRewards;
    mapping(address => address) public referMap;

    event Buy(address indexed addr, uint256 data);
    event Win(address indexed addr, uint256 data);
    event Deposit(address indexed addr, uint256 data);
    event Withdraw(address indexed addr, uint256 data);
    event EndAuction(
        uint256 priceAndTime,
        uint256 clkAmount,
        uint256 buybackAmount
    );

    constructor(address _coin) {
        coin = _coin;
    }

    function fillInitPrice() external {
        if (initPrice != 0) {
            //already filled
            return;
        }
        uint256 initPriceExp = 18;
        (bool success, bytes memory data) = coin.call(
            abi.encodeWithSelector(DECIMALS)
        );
        require(success);
        uint8 decimals = abi.decode(data, (uint8));
        if (decimals < 18) {
            initPriceExp += 18 - decimals;
        }
        (initPrice, coinDecimals) = (uint192(10**initPriceExp), decimals);
    }

    function name() public override returns (string memory) {
        (bool success, bytes memory data) = coin.call(
            abi.encodeWithSelector(NAME)
        );
        require(success);
        return string(abi.encodePacked("CatsLuck Share of ", data));
    }

    function symbol() public override returns (string memory) {
        (bool success, bytes memory data) = coin.call(
            abi.encodeWithSelector(SYMBOL)
        );
        require(success);
        return string(abi.encodePacked("clk", data));
    }

    function safeTransferFrom(address addr, uint256 amount)
        private
        returns (uint256, uint256)
    {
        if (coin == BchAddress) {
            uint256 oldBalance = address(this).balance - msg.value;
            return (msg.value, oldBalance);
        } else {
            require(msg.value == 0, "no bch please");
            uint256 oldBalance = IERC20(coin).balanceOf(address(this));
            IERC20(coin).transferFrom(addr, address(this), amount);
            uint256 newBalance = IERC20(coin).balanceOf(address(this));
            return (newBalance - oldBalance, oldBalance);
        }
    }

    function safeTransfer(address addr, uint256 amount) private {
        (bool success, bytes memory data) = coin.call(
            abi.encodeWithSelector(TRANSFER, addr, amount)
        );
        require(
            success && (data.length == 0 || abi.decode(data, (bool))),
            "transfer failed"
        );
    }

    function getRefererReward() external returns (uint256) {
        uint256 amount = referRewards[msg.sender];
        if (amount != 0) {
            referRewards[msg.sender] = 0;
            totalReferReward -= amount;
            safeTransfer(msg.sender, amount);
        }
        return amount;
    }

    function deposit(uint256 amount, uint256 newLockUntil) external payable {
        uint256 oldBalance;
        (amount, oldBalance) = safeTransferFrom(msg.sender, amount);
        oldBalance = oldBalance - buybackPoolSize - totalReferReward;
        uint256 oldShare = balanceOf(msg.sender);
        uint256 oldLockUntil = lockUntil[msg.sender];
        uint256 oneHourLater = block.timestamp + 3600;
        if (newLockUntil < oneHourLater) newLockUntil = oneHourLater;
        if (oldShare > 0) {
            require(newLockUntil >= oldLockUntil, "invalid lockUntil");
        }
        lockUntil[msg.sender] = newLockUntil;
        uint256 oldTotalSupply = totalSupply();
        if (oldTotalSupply == 0) {
            uint256 decimals = coinDecimals;
            require(amount >= 10**decimals, "less than one coin deposit");
            uint256 firstMintAmount = amount;
            if (decimals < 18) {
                //one coin for one share
                firstMintAmount = amount * (10**(18 - decimals));
            } else if (decimals > 18) {
                firstMintAmount = amount / (10**(decimals - 18));
            }
            _mint(msg.sender, firstMintAmount);
            emit Deposit(
                msg.sender,
                (amount << (96 + 64)) |
                    (firstMintAmount << 64) |
                    block.timestamp
            );
            return;
        }
        // mintAmount / oldTotalSupply = amount / oldBalance
        uint256 mintAmount = (oldTotalSupply * amount) / oldBalance;
        _mint(msg.sender, mintAmount);
        emit Deposit(
            msg.sender,
            (amount << (96 + 64)) | (mintAmount << 64) | block.timestamp
        );
    }

    function myBalance() private view returns (uint256) {
        if (coin == BchAddress) {
            return address(this).balance;
        }
        return IERC20(coin).balanceOf(address(this));
    }

    function info(address addr)
        external
        view
        returns (
            uint256,
            uint256,
            uint256,
            uint256
        )
    {
        uint256 totalUnderlying = myBalance();
        return (
            totalUnderlying - buybackPoolSize - totalReferReward,
            totalSupply(),
            balanceOf(addr),
            lockUntil[addr]
        );
    }

    function maxWithdrawal(address myAddr) external view returns (uint256) {
        uint256 totalUnderlying = myBalance() -
            buybackPoolSize -
            totalReferReward;
        return (totalUnderlying * balanceOf(myAddr)) / totalSupply();
    }

    function withdraw(uint256 amountToBurn) external {
        require(block.timestamp > lockUntil[msg.sender], "still locked");
        uint256 oldBalance = myBalance();
        oldBalance = oldBalance - buybackPoolSize - totalReferReward;
        uint256 oldTotalSupply = totalSupply();
        // deltaBalance / oldBalance = amountToBurn / oldTotalSupply
        uint256 deltaBalance = (oldBalance * amountToBurn) / oldTotalSupply;
        _burn(msg.sender, amountToBurn);
        safeTransfer(msg.sender, deltaBalance);
        emit Withdraw(
            msg.sender,
            (deltaBalance << (96 + 64)) | (amountToBurn << 64) | block.timestamp
        );
    }

    function buyLottery(
        uint256 amount,
        uint256 multiplierX100,
        address referer
    ) external payable {
        address oldReferer = referMap[msg.sender];
        if (oldReferer == address(0)) {
            referMap[msg.sender] = referer;
        } else {
            referer = oldReferer;
        }
        uint256 oldBalance;
        (amount, oldBalance) = safeTransferFrom(msg.sender, amount);
        if (coin == CatsAddress) {
            Mintable(CatsupAddress).mint(msg.sender, amount * (10**16));
        }
        uint256 fee = amount / 40; // totally 2.5% fee, 1.75% for LP, 0.5% for buyback, 0.25% for referer
        uint256 remainedAmount = amount - fee;
        uint256 buybackAmount = amount / 200;
        uint256 referReward = amount / 400;
        if (referer == address(0)) {
            buybackAmount += referReward;
        } else {
            referRewards[referer] += referReward;
            totalReferReward += referReward;
        }
        if (coin == ClkAddress) {
            IERC20(ClkAddress).transfer(address(1), buybackAmount); // 0.5% burnt
        } else {
            buybackPoolSize += buybackAmount; // 0.5% for buyback
        }
        require(
            105 <= multiplierX100 && multiplierX100 <= 100000,
            "invalid multiplier"
        );
        if (multiplierX100 > 300) {
            // remainedAmount*(multiplierX100/100) < oldBalance*0.01
            require(
                remainedAmount * multiplierX100 < oldBalance,
                "amount too large"
            );
        } else {
            // remainedAmount*(multiplierX100/100) < oldBalance*0.005
            require(
                remainedAmount * multiplierX100 * 2 < oldBalance,
                "amount too large"
            );
        }

        buyerTickets[msg.sender] =
            (remainedAmount << 96) |
            (block.number << 32) |
            multiplierX100;
        emit Buy(
            msg.sender,
            (amount << (64 + 32)) | (multiplierX100 << 64) | block.timestamp
        );
    }

    function getLastTicketHeightAndHash()
        public
        view
        returns (uint256, uint256)
    {
        uint256 amountAndHeightAndMul = buyerTickets[msg.sender];
        if (amountAndHeightAndMul == 0) return (0, 0);
        uint256 height = uint256(uint64(amountAndHeightAndMul >> 32));
        bytes32 hash = blockhash(height);
        return (height, uint256(hash));
    }

    function getMyReward(uint256 rdm, bytes calldata pi)
        public
        returns (uint256)
    {
        uint256 amountAndHeightAndMul = buyerTickets[msg.sender];
        if (amountAndHeightAndMul == 0) return 0;
        uint256 multiplierX100 = uint256(uint32(amountAndHeightAndMul));
        uint256 height = uint256(uint64(amountAndHeightAndMul >> 32));
        uint256 amount = amountAndHeightAndMul >> 96;
        bytes32 hash = blockhash(height);
        if (uint256(hash) == 0) return ~uint256(0); // a value with all ones
        delete buyerTickets[msg.sender]; //to prevent replay
        bool ok = VrfGovIfc(VrfgovAddress).verify(uint256(hash), rdm, pi);
        require(ok, "invalid vrf out");
        uint256 rand = uint256(
            keccak256(abi.encodePacked(rdm, amountAndHeightAndMul, msg.sender))
        );
        uint256 reward = 0;
        rand = rand % DIV;
        // rand / DIV <= 100 / multiplierX100
        bool isLucky = rand * multiplierX100 < DIV * 100;
        if (isLucky) {
            reward = (amount * multiplierX100) / 100;
            safeTransfer(msg.sender, reward);
            emit Win(
                msg.sender,
                (reward << (64 + 32)) | (multiplierX100 << 64) | block.timestamp
            );
        }
        return reward;
    }

    function startDutchAuction() external {
        require(auctionStartTime == 0, "auction already started");
        if (auctionPrice == 0) {
            auctionPrice = uint192(initPrice);
        }
        auctionStartTime = uint64(block.timestamp);
        for (uint256 i = 0; i < gasTokens.length; i++) {
            gasTokens[i] = 1;
        }
    }

    function getAuctionTokensAndPrice()
        public
        view
        returns (
            uint256 clkAmount,
            uint256 buybackAmount,
            uint256 price
        )
    {
        require(auctionStartTime != 0, "auction not started");
        price = auctionPrice;
        uint256 timeDiff = block.timestamp - auctionStartTime;
        price >>= timeDiff / (50 * 60);
        timeDiff = timeDiff % (50 * 60);
        price = (price * (100 * 60 - timeDiff)) / (100 * 60);
        buybackAmount = buybackPoolSize;
        clkAmount = (buybackAmount * price) / DIV;
        if (clkAmount == 0) clkAmount = 1;
    }

    function endDutchAuction() external {
        (
            uint256 clkAmount,
            uint256 buybackAmount,
            uint256 price
        ) = getAuctionTokensAndPrice();
        buybackPoolSize = 0;
        auctionPrice = uint128(price * 64);
        auctionStartTime = 0;
        IERC20(ClkAddress).transferFrom(msg.sender, address(1), clkAmount);
        safeTransfer(msg.sender, buybackAmount);
        emit EndAuction(
            (price << 64) | block.timestamp,
            clkAmount,
            buybackAmount
        );
        for (uint256 i = 0; i < gasTokens.length; i++) {
            gasTokens[i] = 0;
        }
    }
}

contract ClkLotteryPoolFactory {
    mapping(address => uint256) public referer2Id;
    address[] public referers;

    event CreateClkLotteryPool(address indexed coin, address indexed poolAddr);

    constructor() {
        referers.push(address(1));
    }

    function getAllReferers() external view returns (address[] memory result) {
        result = referers;
    }

    function registerAsReferer() external {
        require(referer2Id[msg.sender] == 0, "already registered");
        uint256 referId = referers.length;
        referer2Id[msg.sender] = referId;
        referers.push(msg.sender);
    }

    function getPoolAddress(address coin) public view returns (address) {
        bytes memory bytecode = type(ClkLotteryPool).creationCode;
        bytes32 codeHash = keccak256(
            abi.encodePacked(bytecode, abi.encode(coin))
        );
        bytes32 hash = keccak256(
            abi.encodePacked(bytes1(0xff), address(this), bytes32(0), codeHash)
        );
        return address(uint160(uint256(hash)));
    }

    function create(address coin) external {
        ClkLotteryPool pool = new ClkLotteryPool{salt: 0}(coin);
        pool.fillInitPrice();
        emit CreateClkLotteryPool(coin, address(pool));
    }
}
