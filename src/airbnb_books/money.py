RATE_SCALE = 10_000
COP_RATE = 100  # COP lines: minor units are centavos, 1 centavo = 0.01 COP


def to_cop(amount_minor: int, rate: int) -> int:
    """Convert minor units to whole COP: amount_minor * rate / 10 000, half away from zero."""
    product = amount_minor * rate
    rounded = (abs(product) * 2 + RATE_SCALE) // (RATE_SCALE * 2)
    return rounded if product >= 0 else -rounded
