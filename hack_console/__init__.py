from flask import Flask  # Import the Flask class
import os
app = Flask(__name__)    # Create an instance of the class for our use
app.config['MAX_CONTENT_LENGTH'] = 64 * 1000 * 1000

from flask_login import LoginManager, UserMixin
login_manager = LoginManager()
login_manager.init_app(app)


app.secret_key = os.getenv("HACKBOX_SECRET_KEY", "superSecretHackboxKey")
app.config['SESSION_TYPE'] = 'filesystem'




class HackBoxUser(UserMixin):
    id = ""
    username = ""
    password = ""
    role = ""
    def __init__(self, username, password, role):
        self.username = username
        self.password = password
        self.role = role
        self.id = username

def create_all_users():
    allUsers = { }
    # get the directory of the current script
    userJson = os.path.join(os.path.dirname(os.path.dirname(os.path.realpath(__file__))), "users.json")
    if os.path.exists(userJson):
        import json
        with open(userJson, "r") as f:
            for usr in json.load(f):
                if "username" in usr and "password" in usr and "role" in usr:
                    role = str(usr["role"]).lower().strip()
                    if role not in ["hacker", "coach"]:
                        role = "hacker"
                    print(f"Adding user {usr['username']} with role {role}")
                    allUsers[str(usr["username"]).lower().strip()] = HackBoxUser(
                        str(usr["username"]),
                        str(usr["password"]),
                        role
                    )
    # do not load the default users from the enviornment, if the user.json file exists
    if len(allUsers) > 0:
        print("Loaded users from users.json")
        return allUsers
    print("Loading users from environment variables (HACKBOX_HACKER_USER, HACKBOX_HACKER_PWD, HACKBOX_COACH_USER, HACKBOX_COACH_PWD)")
    allUsers[str(os.getenv("HACKBOX_HACKER_USER", "hacker")).lower().strip()] = HackBoxUser(
        os.getenv("HACKBOX_HACKER_USER", "hacker"),
        os.getenv("HACKBOX_HACKER_PWD", "hacker"),
        "hacker"
    )
    allUsers[str(os.getenv("HACKBOX_COACH_USER", "coach")).lower().strip()] = HackBoxUser(
        os.getenv("HACKBOX_COACH_USER", "coach"),
        os.getenv("HACKBOX_COACH_PWD", "coach"),
        "coach"
    )
    return allUsers

all_users = create_all_users()

@login_manager.user_loader
def loader_user(user_id):
    if user_id in all_users:
        return all_users[user_id]
    return None
