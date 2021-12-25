Here you can find the audit report from 0xGuard:

https://github.com/0xGuard-com/audit-reports/blob/master/catsluck/Catsluck_final-audit-report.pdf

Some comments:

1. function buyback is susceptible to sandwich attacks (catsluck) -- Yes, it allows 100% slippage. But in practice, this function is called very frequently by traders and the coins for buyback never accumulate to a high volume, so the slippage is very low, in most cases.

2. Predictable prize (catsluck) -- One of the first principles of probability is the idea of independence. Anytime you withdraw from the pool, the balance can further increase after that, no matter how much it has increased or decreased.

3. lockUntil can be set to minimum value without any side affect (catsluck) -- This variable is not redundant. It is used for the depositors who cannot "control themselves". Sometimes we would like to lock our bitcoins for a period because otherwise we cannot prevent ourselves from selling them.

4. Call usage (catsluck4bch) -- Insufficient contract balance never happens.

5. Open mint (fun) -- Yes, FUN is a demo token that has no value at all with infinite supply. It is designed to be mintable for all the $CATS holders.

1. A player should claim his bet within ~22 minutes (catsluck) -- Yes, this is an EVM limitation. But 22 minutes are enough.

2. Overdue tickets are not deleted from the mapping (catsluck) -- If the gas is refunded, the better must pay more gas the next time he bets.

3. Unsafe token transfer (catsluck) -- Insufficient contract balance never happens.

