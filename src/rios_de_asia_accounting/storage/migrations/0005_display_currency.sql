-- The display currency (decision 48) is kept in settings next to the rate it was chosen with.
-- The old default 'COP' never had a rate, so a stored currency starts over as USD.
UPDATE settings SET value = 'USD' WHERE key = 'currency';
