from datetime import datetime, timedelta
import json, os
from flask import Flask, render_template, request, jsonify, redirect, url_for, send_from_directory
from . import app, all_users, HackBoxUser
from flask_login import login_user, login_required, logout_user, current_user
from azure.data.tables import TableServiceClient
from azure.core.exceptions import ResourceExistsError, ResourceNotFoundError
from typing import Union, Dict
import natsort

# get the directory of this file
challenges_dir = os.path.join(os.path.dirname(os.path.realpath(__file__)), "challenges")
solutions_dir = os.path.join(os.path.dirname(os.path.realpath(__file__)), "solutions")

def recursive_list_md_files(directory: str, starts_with: str = "") -> list:
    files = []
    for root, _, filenames in os.walk(directory):
        for filename in filenames:
            if filename.endswith(".md"):
                if starts_with == "" or filename.startswith(starts_with):
                    f = os.path.join(root, filename)
                    if f.startswith(directory):
                        f = f[len(directory):]
                        if f.startswith("/"):
                            f = f[1:]
                    files.append(f)
    return natsort.natsorted(files)


challenges_mds = recursive_list_md_files(challenges_dir, "challenge")
solutions_mds = recursive_list_md_files(solutions_dir, "solution")

class HackBoxCredentials:
    _tsc = None
    _tc  = None
    _lastGeneratedCustomerId = ""

    def __init__(self):
        self._tsc = TableServiceClient.from_connection_string(conn_str=os.getenv("HACKBOX_CONNECTION_STRING"))
        self._tc = self._tsc.get_table_client("credentials")
    
    def add(self, name: str, credential: str, group: str = "Default") -> None:
        self._tc.upsert_entity(mode="replace", entity={"PartitionKey": group, "RowKey": name, "Credential": credential})
        return self
    def get(self, name: str, group: str = "Default") -> Union[Dict[str, str], None]:
        try:
            entity = self._tc.get_entity(row_key=name, partition_key=group)
            return entity
        except ResourceNotFoundError:
            return None
    def getGroup(self, group : str = "Default") -> Dict[str, Dict[str, str]]:
        group = "".join([c for c in group if c.isalnum() or c == "_"])
        
        entities = {}
        for entity in self._tc.query_entities(query_filter=f"PartitionKey eq '{group}'"):
            entity["group"] = entity["PartitionKey"]
            entity["name"] = entity["RowKey"]
            del entity["PartitionKey"]
            del entity["RowKey"]
            entities[entity["name"]] = entity
        return entities
    def getAll(self) -> Dict[str, Dict[str, str]]:
        entities = []
        for entity in self._tc.list_entities(results_per_page=1000):
            entity["group"] = entity["PartitionKey"]
            entity["name"] = entity["RowKey"]
            del entity["PartitionKey"]
            del entity["RowKey"]
            entities.append(entity)
        return entities

class HackBoxSettings:
    _tsc = None
    _tc  = None
    _lastGeneratedCustomerId = ""

    def __init__(self):
        self._tsc = TableServiceClient.from_connection_string(conn_str=os.getenv("HACKBOX_CONNECTION_STRING"))
        self._tc = self._tsc.get_table_client("settings")
    
    def setStep(self, step: int):
        if step < 1:
            raise ValueError("Step cannot be less than 1")
        self.set("CurrentStep", {"Step": step})
        return self
    def getStep(self) -> int:
        step = self.get("CurrentStep")
        if step is None:
            return 1
        if "Step" not in step:
            return 1
        return step["Step"]
    
    def set(self, key: str, value: Dict[str, Union[str, int, bool]], group : str = "Default") -> None:
        self._tc.upsert_entity(mode="replace", entity={"PartitionKey": group, "RowKey": key, **value})
        return self
    def get(self, key, group : str = "Default") -> Union[Dict[str, Union[str, int, bool]], None]:
        try:
            entity = self._tc.get_entity(row_key=key, partition_key=group)
            return entity
        except ResourceNotFoundError:
            return None
    def getGroup(self, group : str = "Default") -> Dict[str, Union[str, int, bool]]:
        group = "".join([c for c in group if c.isalnum() or c == "_"])
        
        entities = {}
        for entity in self._tc.query_entities(query_filter=f"PartitionKey eq '{group}'"):
            entity["group"] = entity["PartitionKey"]
            entity["key"] = entity["RowKey"]
            del entity["PartitionKey"]
            del entity["RowKey"]
            entities[entity["key"]] = entity
        
        return entities




#region -------- WEB/UI ENDPOINTS --------
@app.route("/")
def home():
    # if the user is not logged in, redirect to the login page
    if not current_user.is_authenticated:
        return redirect(url_for("login"))
    if not isinstance(current_user, HackBoxUser):
        return redirect(url_for("login"))
    return render_template("index.html", user=current_user)

@app.route("/solutions")
def solutions():
    if not current_user.is_authenticated:
        return redirect(url_for("login"))
    if not isinstance(current_user, HackBoxUser):
        logout_user()
        return redirect(url_for("login"))
    if current_user.role != "coach":
        return redirect(url_for("home"))
    return render_template("solutions.html", user=current_user)

@app.route("/credentials")
def credentials():
    if not current_user.is_authenticated:
        return redirect(url_for("login"))
    if not isinstance(current_user, HackBoxUser):
        logout_user()
        return redirect(url_for("login"))
    if current_user.role not in ["coach", "hacker"]:
        return redirect(url_for("home"))
    return render_template("credentials.html", user=current_user)


@app.route("/logout")
def logout():
    logout_user()
    return redirect(url_for("login"))

@app.route("/login", methods=["GET", "POST"])
def login():
    # post request? process the login form
    if request.method == "POST":
        # user exists?
        username = str(request.form.get("username")).lower().strip()
        if username not in all_users:
            return render_template("login.html", message="User not found", user=current_user)
        user = all_users[username]
        # Check the username (again)
        if str(user.username).lower().strip() != username:
            return render_template("login.html", message="Invalid credentials", user=current_user)
        # Check the password
        if user.password == request.form.get("password"):
            # Use the login_user method to log in the user
            login_user(user)
            return redirect(url_for("home"))
        return render_template("login.html", message="Invalid credentials", user=current_user)
    return render_template("login.html", user=current_user)
#endregion -------- WEB/UI ENDPOINTS --------

#region -------- API ENDPOINTS --------

@login_required
@app.route("/api/get/challenge")
def api_get_challenge():
    if not isinstance(current_user, HackBoxUser):
        logout_user()
        return redirect(url_for("login"))
    try:
        hbSettings = HackBoxSettings()
        hbSettings.getStep()
        return jsonify({"success": True, "challenge" : hbSettings.getStep()})
    except Exception as e:
        return jsonify({"success": False, "error": str(e)}), 500


@login_required
@app.route("/api/set/challenge", methods=["POST"])
def api_set_challenge():
    if not isinstance(current_user, HackBoxUser):
        logout_user()
        return redirect(url_for("login"))
    if current_user.role != "coach":
        return jsonify({"success": False, "error": "Unauthorized"}), 403
    try:
        data = request.get_json()
        if "challenge" not in data:
            return jsonify({"success": False, "error": "Missing challenge"}), 400
        hbSettings = HackBoxSettings()
        if str(data["challenge"]).lower().strip() == "decrease":
            data["challenge"] = hbSettings.getStep() - 1
        elif str(data["challenge"]).lower().strip() == "increase":
            data["challenge"] = hbSettings.getStep() + 1
        data["challenge"] = int(data["challenge"])
        if data["challenge"] < 1 or data["challenge"] > len(challenges_mds):
            return jsonify({"success": False, "error": "Challenge not found"}), 404
        hbSettings.setStep(data["challenge"])
        return jsonify({"success": True, "challenge" : hbSettings.getStep()})
    except Exception as e:
        return jsonify({"success": False, "error": str(e)}), 500

@login_required
@app.route("/api/list/challenges")
def api_challenges():
    if not isinstance(current_user, HackBoxUser):
        logout_user()
        return redirect(url_for("login"))
    if current_user.role not in ["coach", "hacker"]:
        return jsonify({"error": "Unauthorized"}), 403
    return jsonify(challenges_mds)

@login_required
@app.route("/api/list/solutions")
def api_solutions():
    if not isinstance(current_user, HackBoxUser):
        logout_user()
        return redirect(url_for("login"))
    if current_user.role not in ["coach"]:
        return jsonify({"error": "Unauthorized"}), 403
    return jsonify(solutions_mds)

@login_required
@app.route("/api/show/credentials")
def api_credentials():
    if not isinstance(current_user, HackBoxUser):
        logout_user()
        return redirect(url_for("login"))
    if current_user.role not in ["coach", "hacker"]:
        return jsonify({"error": "Unauthorized"}), 403
    hbCredentials = HackBoxCredentials()
    return jsonify(hbCredentials.getAll())

@login_required
@app.route("/api/settings", defaults={'group': "Default"})
@app.route("/api/settings/<group>", defaults={'group': "Default"})
def api_config(group : str = 'Default'):
    hbSettings = HackBoxSettings()
    return jsonify(hbSettings.getGroup(group))
#endregion -------- API ENDPOINTS --------

#region -------- STATIC ENDPOINTS --------
@login_required
@app.route('/md/solutions/<path:filename>')
def static_solutions(filename):
    if not isinstance(current_user, HackBoxUser):
        logout_user()
        return redirect(url_for("login"))
    if current_user.role == "coach":
        return send_from_directory(solutions_dir, filename)
    return redirect(url_for("login"))

@login_required
@app.route('/md/challenges/<path:filename>')
def static_challenges(filename):
    if not isinstance(current_user, HackBoxUser):
        logout_user()
        return redirect(url_for("login"))
    if current_user.role in ["coach", "hacker"]:
        return send_from_directory(challenges_dir, filename)
    return redirect(url_for("login"))
#endregion -------- STATIC ENDPOINTS --------
