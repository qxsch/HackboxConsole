class SolutionManager {
    #challenges = [];
    #currentStep = null;
    #currentSolution = null;
    #refreshSeconds = 0;
    #refreshTimeout = null;
    #isSubSite = false;
    constructor() {
        document.getElementById("navToPreviousSolution").style.display = "none";
        document.getElementById("navToPreviousSolution").addEventListener("click", this.navToPreviousSolution.bind(this));
        document.getElementById("navToCurrentSolution").addEventListener("click", this.navToCurrentSolution.bind(this));
        document.getElementById("navToNextSolution").style.display = "none";
        document.getElementById("navToNextSolution").addEventListener("click", this.navToNextSolution.bind(this));

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
                if(href.pathname.startsWith("/md/challenges/") || href.pathname.startsWith("/md/solutions/") && href.pathname.endsWith(".md")) {
                    node.href="#";
                    node.addEventListener("click", function(event) {
                        event.preventDefault();
                        that.gotoSubSiteMd(href.pathname);
                    });
                }
            });
        });
    }

    async getSolutions() {
        return fetch("/api/list/solutions")
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
                this.#challenges = await this.getSolutions();
                console.log("Solutions", this.#challenges);
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
                    if(this.#currentSolution === null) {
                        this.#currentSolution = this.#currentStep;
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
        alert("Solution got revoked, back to the previous challenge!");
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
        if(this.#currentStep < this.#currentSolution) {
            this.#currentSolution = this.#currentStep;
        }
        if(this.#challenges.length === 0) {
            console.log("No challenges available");
            return;
        }
        // not at the first challenge
        if(this.#currentSolution > 1) {
            document.getElementById("navToPreviousSolution").style.display = "block";
        }
        else {
            document.getElementById("navToPreviousSolution").style.display = "none";
        }
        // not at the last challenge
        if(
            this.#currentSolution < this.#challenges.length &&
            this.#currentSolution < this.#currentStep

        ){
            document.getElementById("navToNextSolution").style.display = "block";
        }
        else {
            document.getElementById("navToNextSolution").style.display = "none";
        }

        var mdUrl = "/md/challenges/";
        if(window.defaultSolutionUrl) {
            mdUrl = window.defaultSolutionUrl;
        }
        if(mdUrl.endsWith("/")) {
            mdUrl = mdUrl.substring(0, mdUrl.length - 1);
        }
        if(this.#challenges[this.#currentSolution - 1].startsWith("/")) {
            mdUrl += this.#challenges[this.#currentSolution - 1];
        }
        else {
            mdUrl += "/" + this.#challenges[this.#currentSolution - 1];
        }
        if(document.getElementById("challengeTitle")) {
            document.getElementById("challengeTitle").innerText = "Solution " + this.#currentSolution;
        }
        document.getElementById("zeromd").src = mdUrl;        
    }

    navToPreviousSolution() {
        if(this.#currentSolution > 1) {
            this.#currentSolution--;
            this.#render();
        }
    }

    navToCurrentSolution() {
        if(this.#currentSolution !== this.#currentStep || this.#isSubSite) {
            this.#currentSolution = this.#currentStep;
            this.#render();
        }
    }

    navToNextSolution() {
        if(this.#currentSolution < this.#challenges.length) {
            this.#currentSolution++;
            this.#render();
        }
    }
}


window.solution = new SolutionManager();
window.solution.setPeriodicRefresh(10);


