class ChallengeManager {
    #challenges = [];
    #currentStep = null;
    #currentChallenge = null;
    #refreshSeconds = 0;
    #refreshTimeout = null;
    #isSubSite = true;
    constructor() {
        document.getElementById("navToPreviousChallenge").style.display = "none";
        document.getElementById("navToPreviousChallenge").addEventListener("click", this.navToPreviousChallenge.bind(this));
        document.getElementById("navToCurrentChallenge").addEventListener("click", this.navToCurrentChallenge.bind(this));
        document.getElementById("navToNextChallenge").style.display = "none";
        document.getElementById("navToNextChallenge").addEventListener("click", this.navToNextChallenge.bind(this));
        if(document.getElementById("approveCurrentChallenge")) {
            document.getElementById("approveCurrentChallenge").addEventListener("click", this.approveCurrentChallenge.bind(this));
        }
        if(document.getElementById("revertApproval")) {
            document.getElementById("revertApproval").addEventListener("click", this.revertApproval.bind(this));
        }

        this.#setZeroMdListener();

        this.refresh();
    }

    gotoSubSiteMd(path) {
        if(path.startsWith("/md/challenges/") || path.startsWith("/md/solutions/") && path.endsWith(".md")) {
            this.#isSubSite = true;
            document.getElementById("zeromd").src = path;
        }
    }

    #setZeroMdListener() {
        var that = this;
        var currentUrl = new URL(window.location.href);
        console.log("Current URL", currentUrl);
        document.getElementById("zeromd").addEventListener('zero-md-rendered', function() {
            console.log("configuring markdown links");
            var nodes = document.getElementById("zeromd").shadowRoot.querySelectorAll('a[href]');
            nodes.forEach(function(node) {
                var href = new URL(node.href);
                if(href.host !== currentUrl.host) {
                    // external link
                    node.target = "_blank";
                    return;
                }
                if((href.pathname.startsWith("/md/challenges/") || href.pathname.startsWith("/md/solutions/")) && href.pathname.endsWith(".md")) {
                    node.href="#";
                    node.addEventListener("click", function(event) {
                        event.preventDefault();
                        that.gotoSubSiteMd(href.pathname);
                    });
                }
            });
        });
    }

    async getChallenges() {
        return fetch("/api/list/challenges")
            .then(response => response.json());
    }

    async getUnlockedStep() {
        try {  
            var data = await fetch("/api/get/challenge")
                .then(response => response.json());
            console.log("Current challenge", data);
            if(data.challenge) {
                return parseInt(data.challenge);
            }
        }
        catch {
            console.log("Error fetching current unlocked challenge");
            return 1;
        }
        return 1;
    }

    async refresh() {
        console.log("Refreshing");
        try{
            var requiresRendering = false;
            try {
                this.#challenges = await this.getChallenges();
                console.log("Challenges", this.#challenges);
            }
            catch {
                console.log("Error fetching challenges");
            }
            try {
                var currentStep = await this.getUnlockedStep();
                if(currentStep > 0) {
                    if(this.#currentStep !== currentStep) {
                        requiresRendering = true;
                        if(this.#currentStep !== null) {
                            if(currentStep > this.#currentStep ) {
                                this.#informUserOfNewStep();
                            }
                            else {
                                this.#informUserOfRevokedStep();
                            }
                        }                            
                    }
                    this.#currentStep = currentStep;
                    if(this.#currentChallenge === null) {
                        this.#currentChallenge = this.#currentStep;
                        requiresRendering = true;

                    }
                }
            }
            catch {
                console.log("Error fetching current challenge");
            }
            if(requiresRendering) {
                this.#render();
            }
        }
        finally {
            this.#setRefreshTimer();
        }
    }

    #informUserOfNewStep() {
        alert("Solution got approved, you have unlocked another challenge!");
    }
    #informUserOfRevokedStep() {
        alert("Challenge got revoked, back to the previous challenge!");
    }

    #setRefreshTimer() {
        if(this.#refreshTimeout) {
            clearTimeout(this.#refreshTimeout);
            this.#refreshTimeout = null;
        }
        if(this.#refreshSeconds > 0) {
            this.#refreshTimeout = setTimeout(this.refresh.bind(this), this.#refreshSeconds * 1000);
        }
    }
    setPeriodicRefresh(seconds) {
        seconds = parseFloat(seconds);
        if(seconds < 0) {
            seconds = 0;
        }
        this.#refreshSeconds = seconds;
        this.#setRefreshTimer();
    }
    getPeriodicRefresh() {
        return this.#refreshSeconds;
    }


    #render() {
        if(this.#currentStep < this.#currentChallenge) {
            this.#currentChallenge = this.#currentStep;
        }
        if(this.#challenges.length === 0) {
            console.log("No challenges available");
            return;
        }
        // not at the first challenge
        if(this.#currentChallenge > 1) {
            document.getElementById("navToPreviousChallenge").style.display = "block";
        }
        else {
            document.getElementById("navToPreviousChallenge").style.display = "none";
        }
        // not at the last challenge
        if(
            this.#currentChallenge < this.#challenges.length &&
            this.#currentChallenge < this.#currentStep

        ){
            document.getElementById("navToNextChallenge").style.display = "block";
        }
        else {
            document.getElementById("navToNextChallenge").style.display = "none";
        }
        // not at the last approved challenge
        if(document.getElementById("approveCurrentChallenge")) {
            if(this.#currentStep < this.#challenges.length) {
                document.getElementById("approveCurrentChallenge").style.display = "block";
            }
            else {
                document.getElementById("approveCurrentChallenge").style.display = "none";
            }

        }
        // not at the first approved challenge
        if(document.getElementById("revertApproval")) {
            if(this.#currentStep > 1) {
                document.getElementById("revertApproval").style.display = "block";
            }
            else {
                document.getElementById("revertApproval").style.display = "none";
            }
        }

        var mdUrl = "/md/challenges/";
        if(window.defaultChallengeUrl) {
            mdUrl = window.defaultChallengeUrl;
        }
        if(mdUrl.endsWith("/")) {
            mdUrl = mdUrl.substring(0, mdUrl.length - 1);
        }
        if(this.#challenges[this.#currentChallenge - 1].startsWith("/")) {
            mdUrl += this.#challenges[this.#currentChallenge - 1];
        }
        else {
            mdUrl += "/" + this.#challenges[this.#currentChallenge - 1];
        }
        if(document.getElementById("challengeTitle")) {
            document.getElementById("challengeTitle").innerText = "Challenge " + this.#currentChallenge;
        }
        document.getElementById("zeromd").src = mdUrl;
    }

    navToPreviousChallenge() {
        if(this.#currentChallenge > 1) {
            this.#currentChallenge--;
            this.#render();
        }
    }

    navToCurrentChallenge() {
        if(this.#currentChallenge !== this.#currentStep || this.#isSubSite) {
            this.#isSubSite = false;
            this.#currentChallenge = this.#currentStep;
            this.#render();
        }
    }

    navToNextChallenge() {
        if(this.#currentChallenge < this.#challenges.length) {
            this.#currentChallenge++;
            this.#render();
        }
    }

    async approveCurrentChallenge() {
        var data = await fetch("/api/set/challenge", {
            method: "POST",
            headers: {
                "Content-Type": "application/json"
            },
            body: JSON.stringify({
                "challenge": "increase"
            })
        }).then(response => response.json());
        console.log("Approve response", data);
        this.refresh();
    }

    async revertApproval() {
        var data = await fetch("/api/set/challenge", {
            method: "POST",
            headers: {
                "Content-Type": "application/json"
            },
            body: JSON.stringify({
                "challenge": "decrease"
            })
        }).then(response => response.json());
        console.log("Revert response", data);
        this.refresh();
    }
}


window.challenge = new ChallengeManager();
window.challenge.setPeriodicRefresh(10);


