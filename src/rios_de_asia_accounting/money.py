from decimal import Decimal, InvalidOperation

RATE_SCALE = 1_000_000  # rates: currency units per USD x 1 000 000
USD_RATE = RATE_SCALE


def to_usd(original_minor: int, rate: int) -> int:
    """Minor units of a currency to US cents: original_minor * 1 000 000 / rate, rounded
    half away from zero."""
    num = original_minor * RATE_SCALE
    rounded = (abs(num) * 2 + rate) // (rate * 2)
    return rounded if num >= 0 else -rounded


def parse_minor(text: str) -> int:
    """Parse a decimal amount ("1,234.50", "-0.01") into hundredths, exactly.

    Raises ValueError on junk or more than 2 decimals.
    """
    cleaned = text.strip().replace(",", "")
    try:
        value = Decimal(cleaned)
    except InvalidOperation:
        raise ValueError(f"not an amount: {text!r}") from None
    if not value.is_finite():
        raise ValueError(f"not an amount: {text!r}")
    minor = value * 100
    if minor != minor.to_integral_value():
        raise ValueError(f"more than 2 decimals: {text!r}")
    return int(minor)
