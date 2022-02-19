// SPDX-License-Identifier: MIT
pragma solidity 0.8.10;

import "./IERC20.sol";
import "./Proxy.sol";

contract GuessingGameImpl {
    struct Game {
        uint96 rewardA;
        uint96 spentA;
        uint96 rewardB;
        uint96 spentB;
        uint96 pooledFunds;
        uint96 virtualSpent;
        uint64 lastJudgmentTime;
        uint96 coinsForBuyback;
        uint96 oracleFees;
        bool judged;
        bool afterResultFinalized;
        bool isAWin;
    }

    struct Auction {
        address coin;
        uint64 startTime;
        address oracle;
        uint96 startPrice;
        uint96 coinsForBuyback;
    }

    uint256 private constant DIV = 10**18;
    address private constant CatsAddress =
        0x265bD28d79400D55a1665707Fa14A72978FA6043;
    address private constant ClkAddress =
        0x659F04F36e90143fCaC202D4BC36C699C078fC98;
    address private constant BchAddress =
        0x0000000000000000000000000000000000002711;
    uint256 private constant MinutesIn30Days = 30 * 24 * 60;
    uint256 private constant CoolingOffPeriod = 3600; //1 hour
    uint256 private constant MaxNumKindsOfCoins = 2**13;
    uint256 private constant CoinIdMask = MaxNumKindsOfCoins - 1;

    uint256[100] private placeholder;
    mapping(uint256 => Game) public gameMap;
    mapping(uint256 => Auction) public auctionMap;

    mapping(address => uint256) public auctionPrice;
    mapping(address => address[MaxNumKindsOfCoins]) private coinsUsedByOracle;
    mapping(address => uint256) private numKindsOfCoinsUsedByOracle;

    mapping(address => mapping(uint256 => uint256)) private rewardAMap;
    mapping(address => mapping(uint256 => uint256)) private rewardBMap;
    mapping(address => mapping(uint256 => uint256)) private spentAMap;
    mapping(address => mapping(uint256 => uint256)) private spentBMap;

    mapping(address => mapping(address => uint256)) public riskyCoinsOfOracle;
    mapping(address => uint256) private numTotalAndOngoingGamesOfOracle;

    mapping(address => uint256) private oracleTotalBurntClk;

    mapping(address => uint256) private oracleLockedClk;
    mapping(address => uint256) public friendAndTime;

    event SetFriend(address sender, address friend, uint256 timestamp);
    event Transfer(address indexed _from, address indexed _to, uint256 _value);
    event NewGame(
        address indexed oracle,
        uint256 indexed gameId,
        uint256 initLiquidityMargin,
        uint256 spentA,
        uint256 spentB,
        uint256 timestamp,
        uint256 ownedCLKAndCats,
        bytes memo
    );
    event GuessA(
        address indexed guesser,
        uint256 indexed gameId,
        uint256 amount,
        uint256 reward,
        uint256 timestamp
    );
    event GuessB(
        address indexed guesser,
        uint256 indexed gameId,
        uint256 amount,
        uint256 reward,
        uint256 timestamp
    );
    event RewardA(
        address indexed guesser,
        uint256 indexed gameId,
        uint256 amount,
        uint256 reward,
        uint256 timestamp
    );
    event RewardB(
        address indexed guesser,
        uint256 indexed gameId,
        uint256 amount,
        uint256 reward,
        uint256 timestamp
    );
    event TakeBack(
        address indexed guesser,
        uint256 indexed gameId,
        uint256 amount,
        uint256 timestamp
    );
    event RewardOracle(
        address indexed oracle,
        uint256 indexed gameId,
        uint256 reward,
        uint256 timestamp
    );
    event EndAuction(
        uint256 gameId,
        uint256 price,
        uint256 clkAmount,
        uint256 coinsForBuyback,
        uint256 timestamp
    );
    event PromoteGame(uint256 gameId, uint256 amount, uint256 timestamp);

    // limited ERC20 implementation for oracles to transfer locked CLK
    function name() public pure returns (string memory) {
        return "GuessingGame";
    }

    function symbol() public pure returns (string memory) {
        return "GGT";
    }

    function balanceOf(address oracle) public view returns (uint256) {
        return oracleLockedClk[oracle];
    }

    function decimals() public pure returns (uint8) {
        return 18;
    }

    function totalSupply() public view returns (uint256) {
        return IERC20(ClkAddress).balanceOf(address(this)); //TOTEST
    }

    function transferFrom(
        address _from,
        address _to,
        uint256 _value
    ) public pure returns (bool success) {
        return true; //Do nothing
    }

    function approve(address _spender, uint256 _value)
        public
        pure
        returns (bool success)
    {
        return true; //Do nothing
    }

    function allowance(address _owner, address _spender)
        public
        pure
        returns (uint256 remaining)
    {
        return 0; //Do nothing
    }

    function setFriend(address friend) external {
        require(friend != msg.sender, "not a friend");
        friendAndTime[msg.sender] =
            (uint256(uint160(friend)) << 64) +
            block.timestamp;
        emit SetFriend(msg.sender, friend, block.timestamp);
    }

    function transfer(address receiver, uint256 value)
        public
        returns (bool success)
    {
        uint256 fat = friendAndTime[receiver];
        require(
            address(uint160(fat >> 64)) == msg.sender,
            "not receiver's friend"
        );
        require(
            uint256(uint64(fat)) + 7 days < block.timestamp,
            "not old friend"
        ); // 7 days
        uint256 allGGT = oracleLockedClk[msg.sender];
        require(allGGT == value, "must transfer all GGT");
        oracleLockedClk[receiver] += allGGT; // send locked clk to receiver
        oracleLockedClk[msg.sender] = 0;
        friendAndTime[receiver] = 0; // clear friend
        emit Transfer(msg.sender, receiver, value);
        IERC20(ClkAddress).transferFrom(receiver, msg.sender, allGGT); // send normal clk to sender
        return true;
    }

    function fromGameId(uint256 gameId)
        public
        pure
        returns (
            address oracle,
            uint256 startTime,
            uint256 guessDeadline,
            uint256 judgeDeadline,
            uint256 coinId
        )
    {
        oracle = address(uint160(gameId >> 96));
        startTime = uint256(uint32(gameId >> 64));
        guessDeadline = startTime + uint256(uint16(gameId >> 48));
        judgeDeadline = startTime + uint256(uint16(gameId >> 32));
        startTime *= 60;
        guessDeadline *= 60;
        judgeDeadline *= 60;
        coinId = gameId & CoinIdMask;
    }

    function getValidGameId(uint256 gameId) external view returns (uint256) {
        for (uint256 i = 0; i < (1 << 32); i += MaxNumKindsOfCoins) {
            if (gameMap[gameId + i].pooledFunds == 0) return gameId + i; // an empty slot
        }
        return 0;
    }

    function queryMySpentAndRewards(uint256[] calldata gameIds)
        external
        view
        returns (uint256[] memory results)
    {
        results = new uint256[](4 * gameIds.length);
        for (uint256 i = 0; i < gameIds.length; i++) {
            uint256 id = gameIds[i];
            results[4 * i + 0] = rewardAMap[msg.sender][id];
            results[4 * i + 1] = rewardBMap[msg.sender][id];
            results[4 * i + 2] = spentAMap[msg.sender][id];
            results[4 * i + 3] = spentBMap[msg.sender][id];
        }
    }

    function queryCoinsUsedInGames(uint256[] calldata gameIds)
        external
        view
        returns (address[] memory coins)
    {
        coins = new address[](gameIds.length);
        for (uint256 i = 0; i < gameIds.length; i++) {
            uint256 gameId = gameIds[i];
            address oracle = address(uint160(gameId >> 96));
            uint256 coinId = gameId & CoinIdMask;
            coins[i] = coinsUsedByOracle[oracle][coinId];
        }
    }

    function queryOracleCoins(address oracle)
        external
        view
        returns (address[] memory coins)
    {
        coins = new address[](numKindsOfCoinsUsedByOracle[oracle]);
        for (uint256 i = 0; i < coins.length; i++) {
            coins[i] = coinsUsedByOracle[oracle][i];
        }
    }

    function queryOracleCoinsAndRisks(address oracle)
        external
        view
        returns (address[] memory coins, uint256[] memory risks)
    {
        uint256 size = numKindsOfCoinsUsedByOracle[oracle];
        coins = new address[](size);
        risks = new uint256[](size);
        for (uint256 i = 0; i < coins.length; i++) {
            address coin = coinsUsedByOracle[oracle][i];
            coins[i] = coin;
            risks[i] = riskyCoinsOfOracle[oracle][coin];
        }
    }

    function oracleStatusList(address[] calldata oracleList)
        external
        view
        returns (uint256[] memory statusList)
    {
        statusList = new uint256[](3 * oracleList.length);
        for (uint256 i = 0; i < oracleList.length; i++) {
            address oracle = oracleList[i];
            statusList[3 * i + 0] = numTotalAndOngoingGamesOfOracle[oracle];
            statusList[3 * i + 1] = oracleLockedClk[oracle];
            statusList[3 * i + 2] = oracleTotalBurntClk[oracle];
        }
    }

    function safeTransferFrom(
        address coin,
        address addr,
        uint256 amount
    ) private returns (uint256) {
        uint256 oldBalance = IERC20(coin).balanceOf(address(this));
        IERC20(coin).transferFrom(addr, address(this), amount);
        uint256 newBalance = IERC20(coin).balanceOf(address(this));
        return (newBalance - oldBalance);
    }

    function safeTransfer(
        address coin,
        address addr,
        uint256 amount
    ) private {
        (bool success, bytes memory data) = coin.call(
            abi.encodeWithSignature("transfer(address,uint256)", addr, amount)
        );
        require(success, "transfer failed");
    }

    function addLockedCLK(uint256 amount) external {
        IERC20(ClkAddress).transferFrom(msg.sender, address(this), amount);
        oracleLockedClk[msg.sender] += amount;
        emit Transfer(address(0), msg.sender, amount); //mint GGT
    }

    function createGameWithNewCoin(
        address coin,
        uint256 gameId,
        uint256 spentA,
        uint256 spentB,
        uint256 initLiquidityMargin,
        bytes calldata memo
    ) external payable {
        require(coin != address(0), "invalid coin");
        uint256 coinId = gameId & CoinIdMask;
        require(
            coinId == numKindsOfCoinsUsedByOracle[msg.sender],
            "invalid coinId"
        );
        for (uint256 id = 0; id < coinId; id++) {
            require(
                coin != coinsUsedByOracle[msg.sender][id],
                "already used coin"
            );
        }
        coinsUsedByOracle[msg.sender][coinId] = coin;
        numKindsOfCoinsUsedByOracle[msg.sender] = coinId + 1;
        _createGame(coin, gameId, spentA, spentB, initLiquidityMargin, memo);
    }

    function createGame(
        uint256 gameId,
        uint256 spentA,
        uint256 spentB,
        uint256 initLiquidityMargin,
        bytes calldata memo
    ) external payable {
        uint256 coinId = gameId & CoinIdMask;
        require(
            coinId < numKindsOfCoinsUsedByOracle[msg.sender],
            "invalid coinId"
        );
        address coin = coinsUsedByOracle[msg.sender][coinId];
        _createGame(coin, gameId, spentA, spentB, initLiquidityMargin, memo);
    }

    function _createGame(
        address coin,
        uint256 gameId,
        uint256 spentA,
        uint256 spentB,
        uint256 initLiquidityMargin,
        bytes calldata memo
    ) private {
        uint256 guessTimeSpan = uint256(uint16(gameId >> 48));
        uint256 gameTimeSpan = uint256(uint16(gameId >> 32));
        require(guessTimeSpan < gameTimeSpan, "invalid game time");
        require(gameTimeSpan < MinutesIn30Days, "game time too long");
        address oracle = address(uint160(gameId >> 96));
        require(msg.sender == oracle, "not oracle");
        require(
            initLiquidityMargin != 0,
            "initLiquidityMargin must be non-zero"
        );
        Game memory game = gameMap[gameId];
        require(game.pooledFunds == 0, "game already created");
        if (coin == BchAddress) {
            require(initLiquidityMargin == msg.value, "value mismatch");
        } else {
            require(msg.value == 0, "nonzero value");
            initLiquidityMargin = safeTransferFrom(
                coin,
                msg.sender,
                initLiquidityMargin
            );
        }
        game.pooledFunds = uint96(initLiquidityMargin);
        game.spentA = uint96(spentA);
        game.spentB = uint96(spentB);
        game.virtualSpent = game.spentA + game.spentB;
        game.rewardA = 0;
        game.rewardB = 0;
        game.lastJudgmentTime = 0;
        game.judged = false;
        game.afterResultFinalized = false;
        game.isAWin = false;
        game.coinsForBuyback = 0;
        game.oracleFees = 0;
        gameMap[gameId] = game;
        uint256 ownedCLK = IERC20(ClkAddress).balanceOf(oracle);
        ownedCLK += oracleLockedClk[oracle];
        uint256 ownedCLKAndCats = (ownedCLK << 96) +
            IERC20(CatsAddress).balanceOf(oracle);
        emit NewGame(
            oracle,
            gameId,
            initLiquidityMargin,
            spentA,
            spentB,
            block.timestamp,
            ownedCLKAndCats,
            memo
        );
    }

    function guessA(
        uint256 gameId,
        uint256 amount,
        uint256 minReward
    ) external payable returns (uint256 reward) {
        return _guess(gameId, amount, minReward, true);
    }

    function guessB(
        uint256 gameId,
        uint256 amount,
        uint256 minReward
    ) external payable returns (uint256 reward) {
        return _guess(gameId, amount, minReward, false);
    }

    function max(uint256 a, uint256 b) private pure returns (uint256) {
        if (a > b) return a;
        return b;
    }

    function _guess(
        uint256 gameId,
        uint256 amount,
        uint256 minReward,
        bool isA
    ) private returns (uint256 reward) {
        address oracle;
        address coin;
        if (true) {
            uint256 startTime;
            uint256 guessDeadline;
            uint256 _dummy;
            uint256 coinId;
            (oracle, startTime, guessDeadline, _dummy, coinId) = fromGameId(
                gameId
            );
            coin = coinsUsedByOracle[oracle][coinId];
            if (coin == BchAddress) {
                require(amount == msg.value, "value mismatch");
            } else {
                require(msg.value == 0, "nonzero value");
                amount = safeTransferFrom(coin, msg.sender, amount);
            }
            require(
                startTime <= block.timestamp && block.timestamp < guessDeadline,
                "invalid guess time"
            );
        }
        Game memory game = gameMap[gameId];
        uint96 fee = uint96(amount / 100);
        require(fee != 0, "zero fee");
        game.oracleFees += 2 * fee; // 2%
        game.coinsForBuyback += fee; // 1%
        amount -= 3 * fee;
        require(game.pooledFunds != 0, "no such game");
        (uint256 rewardA, uint256 rewardB) = (game.rewardA, game.rewardB);
        if (rewardA == 0 && rewardB == 0) {
            // first guesser
            numTotalAndOngoingGamesOfOracle[oracle] += 1;
        }
        uint256 newRiskyCoins = riskyCoinsOfOracle[oracle][coin] -
            max(rewardA, rewardB);
        uint256 newPooledFunds = game.pooledFunds + amount;
        if (isA) {
            reward =
                ((amount + game.spentA + game.spentB) * amount) /
                (amount + game.spentA);
            if (reward + rewardA > newPooledFunds) {
                reward = newPooledFunds - rewardA;
            }
            reward = (reward * 97) / 100;
            rewardA += reward;
            rewardAMap[msg.sender][gameId] += reward;
            spentAMap[msg.sender][gameId] += amount;
            game.spentA += uint96(amount);
        } else {
            reward =
                ((amount + game.spentA + game.spentB) * amount) /
                (amount + game.spentB);
            if (reward + rewardB > newPooledFunds) {
                reward = newPooledFunds - rewardB;
            }
            reward = (reward * 97) / 100;
            rewardB += reward;
            rewardBMap[msg.sender][gameId] += reward;
            spentBMap[msg.sender][gameId] += amount;
            game.spentB += uint96(amount);
        }
        require(reward > minReward, "reward not enough");
        game.pooledFunds = uint96(newPooledFunds);
        riskyCoinsOfOracle[oracle][coin] =
            newRiskyCoins +
            max(rewardA, rewardB);
        (game.rewardA, game.rewardB) = (uint96(rewardA), uint96(rewardB));
        gameMap[gameId] = game;
        if (isA) {
            emit GuessA(msg.sender, gameId, amount, reward, block.timestamp);
        } else {
            emit GuessB(msg.sender, gameId, amount, reward, block.timestamp);
        }
    }

    function judgeAWin(uint256 gameId) external {
        _judge(gameId, true);
    }

    function judgeBWin(uint256 gameId) external {
        _judge(gameId, false);
    }

    function _judge(uint256 gameId, bool isAWin) private {
        (
            address oracle,
            uint256 startTime,
            uint256 guessDeadline,
            uint256 judgeDeadline,
            uint256 coinId
        ) = fromGameId(gameId);
        require(oracle == msg.sender, "not oracle");
        require(
            guessDeadline <= block.timestamp && block.timestamp < judgeDeadline,
            "invalid judge time"
        );
        Game memory game = gameMap[gameId];
        require(game.pooledFunds != 0, "no such game");
        if (game.judged) {
            // oracle can change old judgment, during the cooling-off period
            require(
                block.timestamp < game.lastJudgmentTime + CoolingOffPeriod,
                "too late to change judgment"
            );
        }
        game.lastJudgmentTime = uint64(block.timestamp);
        game.judged = true;
        game.isAWin = isAWin;
        gameMap[gameId] = game;
    }

    function getRewardForGuessers(address[] calldata guessers, uint256 gameId)
        external
    {
        for (uint256 i = 0; i < guessers.length; i++) {
            _getReward(false, guessers[i], gameId);
        }
    }

    function getReward(uint256 gameId) external returns (uint256) {
        return _getReward(false, msg.sender, gameId);
    }

    function getOracleReward(uint256 gameId) external returns (uint256) {
        return _getReward(true, msg.sender, gameId);
    }

    function _getReward(
        bool forOracle,
        address myAddr,
        uint256 gameId
    ) private returns (uint256) {
        Game memory game = gameMap[gameId];
        address oracle;
        address coin;
        if (true) {
            uint256 startTime;
            uint256 guessDeadline;
            uint256 judgeDeadline;
            uint256 coinId;
            (
                oracle,
                startTime,
                guessDeadline,
                judgeDeadline,
                coinId
            ) = fromGameId(gameId);
            coin = coinsUsedByOracle[oracle][coinId];
            require(
                block.timestamp >= judgeDeadline ||
                    block.timestamp >= game.lastJudgmentTime + CoolingOffPeriod,
                "still waiting for judgment"
            );
        }
        if (!game.afterResultFinalized) {
            game = onResultFinalized(game, oracle, coin, gameId);
        }
        uint256 reward;
        if (forOracle) {
            require(
                myAddr == oracle && game.judged,
                "cannot get oracle reward"
            );
            uint96 winnerReward = game.isAWin ? game.rewardA : game.rewardB;
            reward = game.pooledFunds - winnerReward + game.oracleFees;
            game.oracleFees = 0;
            game.pooledFunds = winnerReward;
            emit RewardOracle(myAddr, gameId, reward, block.timestamp);
        } else {
            if (game.judged) {
                if (game.isAWin) {
                    reward = rewardAMap[myAddr][gameId];
                    game.rewardA -= uint96(reward);
                    uint256 spentA = spentAMap[myAddr][gameId];
                    game.spentA -= uint96(spentA);
                    rewardAMap[myAddr][gameId] = 0;
                    spentAMap[myAddr][gameId] = 0;
                    emit RewardA(
                        myAddr,
                        gameId,
                        spentA,
                        reward,
                        block.timestamp
                    );
                } else {
                    reward = rewardBMap[myAddr][gameId];
                    game.rewardB -= uint96(reward);
                    uint256 spentB = spentBMap[myAddr][gameId];
                    game.spentB -= uint96(spentB);
                    rewardBMap[myAddr][gameId] = 0;
                    spentBMap[myAddr][gameId] = 0;
                    emit RewardB(
                        myAddr,
                        gameId,
                        spentB,
                        reward,
                        block.timestamp
                    );
                }
            } else {
                uint256 spentA = spentAMap[myAddr][gameId];
                spentAMap[myAddr][gameId] = 0;
                uint256 spentB = spentBMap[myAddr][gameId];
                spentBMap[myAddr][gameId] = 0;
                require(spentA + spentB != 0, "nothing to take back");
                reward =
                    (game.pooledFunds * (spentA + spentB)) /
                    (game.spentA + game.spentB - game.virtualSpent);
                game.spentA -= uint96(spentA);
                game.spentB -= uint96(spentB);
                emit TakeBack(myAddr, gameId, reward, block.timestamp);
            }
            game.pooledFunds -= uint96(reward);
        }
        if (reward != 0) {
            safeTransfer(coin, myAddr, reward);
        }
        if (game.spentA == 0 && game.spentB == 0) {
            delete gameMap[gameId];
        } else {
            gameMap[gameId] = game;
        }
        return reward;
    }

    function onResultFinalized(
        Game memory game,
        address oracle,
        address coin,
        uint256 gameId
    ) private returns (Game memory) {
        game.afterResultFinalized = true;
        numTotalAndOngoingGamesOfOracle[oracle] =
            numTotalAndOngoingGamesOfOracle[oracle] +
            (1 << 64) -
            1;
        riskyCoinsOfOracle[oracle][coin] -= max(game.rewardA, game.rewardB);
        if (game.judged) {
            //start auction to buyback clk
            if (game.coinsForBuyback != 0) {
                Auction memory auction;
                auction.oracle = oracle;
                auction.coin = coin;
                auction.startPrice = uint96(auctionPrice[coin] * 4); //TOTEST
                auction.startTime = uint64(block.timestamp);
                auction.coinsForBuyback = game.coinsForBuyback;
                if (auction.startPrice == 0) {
                    auction.startPrice = uint96(DIV);
                }
                auctionMap[gameId] = auction;
            }
        } else {
            //spenders get all coins
            game.pooledFunds += game.coinsForBuyback + game.oracleFees;
            game.oracleFees = 0;
        }
        game.coinsForBuyback = 0;
        return game;
    }

    function endAuction(uint256 gameId) external returns (uint256, uint256) {
        Auction memory auction = auctionMap[gameId];
        require(auction.startTime != 0, "auction not started");
        uint256 price = auction.startPrice;
        uint256 timeDiff = block.timestamp - auction.startTime;
        price >>= timeDiff / (50 * 60); // halving every 50 minutes
        timeDiff = timeDiff % (50 * 60);
        price = (price * (100 * 60 - timeDiff)) / (100 * 60); // drop 1% every minute
        uint256 coinsForBuyback = auction.coinsForBuyback;
        uint256 clkAmount = (coinsForBuyback * price) / DIV;
        auctionPrice[auction.coin] = price;
        IERC20(ClkAddress).transferFrom(msg.sender, address(1), clkAmount); //burn sender's clk
        safeTransfer(auction.coin, msg.sender, coinsForBuyback);
        oracleTotalBurntClk[auction.oracle] += clkAmount;
        uint256 lockedClk = oracleLockedClk[auction.oracle];
        if (clkAmount >= lockedClk) {
            clkAmount = lockedClk;
        }
        safeTransfer(ClkAddress, auction.oracle, clkAmount);
        oracleLockedClk[auction.oracle] = lockedClk - clkAmount;
        emit Transfer(msg.sender, address(0), clkAmount); //burn GGT
        emit EndAuction(
            gameId,
            price,
            clkAmount,
            coinsForBuyback,
            block.timestamp
        );
        delete auctionMap[gameId];
        return (clkAmount, coinsForBuyback);
    }

    function clearOld(
        uint256 gameId,
        address[] calldata guessersA,
        address[] calldata guessersB
    ) external payable {
        Game memory game = gameMap[gameId];
        uint256 startTime = uint256(uint32(gameId >> 64));
        require(
            (startTime + 2 * MinutesIn30Days) * 60 < block.timestamp,
            "not old"
        );
        require(game.pooledFunds == 0 && game.oracleFees == 0, "still active");
        for (uint256 i = 0; i < guessersA.length; i++) {
            rewardAMap[guessersA[i]][gameId] = 0;
            spentAMap[guessersA[i]][gameId] = 0;
        }
        for (uint256 i = 0; i < guessersB.length; i++) {
            rewardBMap[guessersB[i]][gameId] = 0;
            spentBMap[guessersB[i]][gameId] = 0;
        }
    }

    function promoteGame(uint256 gameId, uint256 amount) external {
        address oracle = address(uint160(gameId >> 96));
        require(amount != 0, "zero amount");
        require(msg.sender == oracle, "not oracle");
        IERC20(CatsAddress).transferFrom(msg.sender, address(1), amount); //burn sender's cats
        emit PromoteGame(gameId, amount, block.timestamp);
    }
}

contract GuessingGame is Proxy {
    address public owner;
    address public impl;
    address public nextImpl;
    address public nextOwner;
    uint256 public upgradeTime;
    address private constant BchAddress =
        0x0000000000000000000000000000000000002711;

    uint256 public constant UpgradeDelayPeriod = 10 days; //10 days

    constructor(address _owner, address _impl) {
        owner = _owner;
        impl = _impl;
    }

    function setNextOwner(address _nextOwner) external {
        require(msg.sender == owner, "not owner");
        if (_nextOwner == BchAddress) {
            owner = BchAddress;
        } else {
            nextOwner = _nextOwner;
        }
    }

    function switchOwner() external {
        require(msg.sender == nextOwner, "not owner");
        owner = nextOwner;
    }

    function setNextImpl(address _impl, uint256 _upgradeTime) external {
        require(msg.sender == owner, "not owner");
        require(
            _upgradeTime > block.timestamp + UpgradeDelayPeriod,
            "delay too short"
        );
        upgradeTime = _upgradeTime;
        nextImpl = _impl;
    }

    function upgrade() external {
        require(upgradeTime != 0 && block.timestamp > upgradeTime, "not ready");
        impl = nextImpl;
        nextImpl = address(0);
        upgradeTime = 0;
    }

    function _implementation() internal view override returns (address) {
        return impl;
    }
}
