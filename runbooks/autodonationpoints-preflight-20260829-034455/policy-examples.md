# Non-executed policy examples

No policy was activated and no retroactive or starting credits are included.

## 1. Conservative — approximately one point per online account-hour

```ini
AutoDonationPoints.Enable = 1
AutoDonationPoints.IntervalMs = 3600000
AutoDonationPoints.Amount = 1
AutoDonationPoints.FlushIntervalMs = 300000
```

- Rate: 1 point per completed 60 eligible online minutes per account.
- Nominal crash-loss window: less than 5 minutes since the last successful
  progress flush; not guaranteed if an async write fails.
- GM and AFK time: counted.
- Steady write rate: 12 progress flush opportunities per account-hour plus two
  grant statements. Depending on timer coincidence, approximately 13-14 SQL
  writes per eligible account-hour, plus one synchronous initial SELECT per
  account per process start.

## 2. Moderate — approximately one point per 30 online account-minutes

```ini
AutoDonationPoints.Enable = 1
AutoDonationPoints.IntervalMs = 1800000
AutoDonationPoints.Amount = 1
AutoDonationPoints.FlushIntervalMs = 300000
```

- Rate: 2 points per completed eligible online hour, granted one at a time every
  30 minutes.
- Nominal crash-loss window: less than 5 minutes, subject to the same async-error
  caveat.
- GM and AFK time: counted.
- Steady write rate: 12 flush opportunities plus four grant statements;
  approximately 14-16 SQL writes per eligible account-hour depending on timer
  coincidence, plus one initial SELECT.

## 3. Shipped source default

```ini
AutoDonationPoints.Enable = 0
AutoDonationPoints.IntervalMs = 3600000
AutoDonationPoints.Amount = 1
AutoDonationPoints.FlushIntervalMs = 300000
```

- Exact behavior: disabled; zero grants, loads, flushes, and feature database
  writes.
- If only `Enable` were changed to 1, the remaining defaults would produce the
  conservative policy above.

## Current configured policy

The current active file specifies 100 points per 60 minutes, not any of the three
requested examples. This preflight recommends the conservative choice for a
controlled first test.
