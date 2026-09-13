from datetime import datetime, timedelta, timezone

import pytest

from callback_audit.timeparse import TimeParseError, day_key, humanize, parse_ts

UTC = timezone.utc


def test_epoch_seconds_and_milliseconds():
    assert parse_ts("1614265330") == datetime(2021, 2, 25, 15, 2, 10, tzinfo=UTC)
    assert parse_ts(1614265330) == datetime(2021, 2, 25, 15, 2, 10, tzinfo=UTC)
    assert parse_ts("1614265330000") == datetime(2021, 2, 25, 15, 2, 10, tzinfo=UTC)


def test_iso_variants():
    assert parse_ts("2026-09-13T09:00:00Z") == datetime(2026, 9, 13, 9, 0, tzinfo=UTC)
    assert parse_ts("2026-09-13T16:00:00+07:00") == datetime(2026, 9, 13, 9, 0, tzinfo=UTC)
    assert parse_ts("2026-09-13 09:00:00") == datetime(2026, 9, 13, 9, 0, tzinfo=UTC)  # naive = UTC
    assert parse_ts("2026-09-13T09:00:00.123456Z") == datetime(2026, 9, 13, 9, 0, 0, 123456, tzinfo=UTC)


def test_common_log_format():
    assert parse_ts("10/Sep/2026:13:55:36 +0000") == datetime(2026, 9, 10, 13, 55, 36, tzinfo=UTC)
    assert parse_ts("10/Sep/2026:13:55:36 -0700") == datetime(2026, 9, 10, 20, 55, 36, tzinfo=UTC)
    assert parse_ts("10/Sep/2026:13:55:36") == datetime(2026, 9, 10, 13, 55, 36, tzinfo=UTC)


def test_aware_datetime_passthrough_is_converted():
    local = datetime(2026, 9, 13, 16, 0, tzinfo=timezone(timedelta(hours=7)))
    assert parse_ts(local) == datetime(2026, 9, 13, 9, 0, tzinfo=UTC)


@pytest.mark.parametrize("bad", ["", "yesterday", "2026-13-45", "12:00"])
def test_invalid(bad):
    with pytest.raises(TimeParseError):
        parse_ts(bad)


def test_day_key_and_humanize():
    assert day_key(datetime(2026, 9, 13, 23, 30, tzinfo=timezone(timedelta(hours=-3)))) == "2026-09-14"
    assert humanize(timedelta(days=2, hours=3, minutes=7)) == "2d 3h"
    assert humanize(timedelta(hours=1, minutes=7)) == "1h 7m"
    assert humanize(timedelta(minutes=7)) == "7m"
