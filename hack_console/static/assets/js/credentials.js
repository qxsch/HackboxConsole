
// one off loader
(async function() {
    var creds = await fetch('/api/show/credentials').then(response => response.json());
    console.log(creds);
    const rootEl = document.getElementById('credentials');
    rootEl.innerHTML = '';

    var newDict = {};
    for (var i in creds) {
        var g = creds[i].group;
        if(!(g in newDict)) {
            newDict[g] = [];
        }
        newDict[g].push(creds[i]);
    }
    console.log(newDict);

    // iterate over dict
    for (var key in newDict) {
        var title = document.createElement('h2');
        title.innerText = "Credential Group " + String(key);
        rootEl.appendChild(title);

        var tblEl = document.createElement('table');
        var trHeader = document.createElement('tr');
        var th1 = document.createElement('th');
        th1.innerText = 'Name';
        trHeader.appendChild(th1);
        var th2 = document.createElement('th');
        th2.innerText = 'Credential';
        trHeader.appendChild(th2);
        tblEl.appendChild(trHeader);
        newDict[key].forEach(cred => {
            var tr = document.createElement('tr');
            
            var td1 = document.createElement('td');
            td1.innerText = cred.name;
            td1.classList.add('name');
            tr.appendChild(td1);

            var td2 = document.createElement('td');
            td2.dataset.Credential = cred.Credential;
            td2.classList.add('hidden');
            td2.classList.add('credential');
            td2.addEventListener('click', function() {
                this.classList.toggle('hidden');
                if (this.classList.contains('hidden')) {
                    this.innerText = '';
                }
                else {
                    this.innerText = this.dataset.Credential;
                }
            });
            tr.appendChild(td2);

            tblEl.appendChild(tr);
        });
        rootEl.appendChild(tblEl);
    }

})();