import base58

def ss58_to_account_id(ss58_address: str) -> bytes:
    """
    Converts an SS58 address to a 32-byte account id.

    Args:
        ss58_address (str): The SS58 encoded address.

    Returns:
        bytes: The 32-byte account id.
    """
    decoded = base58.b58decode(ss58_address)
    # SS58 Format: [<1b/2b prefix>][32b account id][1-2b checksum]
    # Identify prefix length (1 or 2 bytes)
    prefix = decoded[0]
    if prefix < 64:
        account_id = decoded[1:33]
    else:
        # 2-byte prefix
        account_id = decoded[2:34]
    if len(account_id) != 32:
        raise ValueError("Invalid account id length decoded from the ss58 address")
    return account_id

if __name__ == "__main__":
    # Example usage:
    ss58_address = input("Enter SS58 address: ").strip()
    account_id = ss58_to_account_id(ss58_address)
    print("Account ID (hex):", account_id.hex())
