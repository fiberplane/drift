class UserProfile:
    def __init__(self, name: str):
        self.name = name

def validate_email(email: str) -> bool:
    return "@" in email
