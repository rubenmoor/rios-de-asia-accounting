DROP INDEX time_log_date;
DROP TABLE time_log;
DELETE FROM settings WHERE key = 'hourly_value_cop';
