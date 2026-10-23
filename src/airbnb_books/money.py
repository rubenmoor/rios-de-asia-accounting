from decimal import Decimal, InvalidOperation

RATE_SCALE = 10_000
COP_RATE = 100  # COP lines: minor units are centavos, 1 centavo = 0.01 COP


def to_cop(amount_minor: int, rate: int) -> int:
    """Convert minor units to whole COP: amount_minor * rate / 10 000, half away from zero."""
    product = amount_minor * rate
    rounded = (abs(product) * 2 + RATE_SCALE) // (RATE_SCALE * 2)
    return rounded if product >= 0 else -rounded


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
