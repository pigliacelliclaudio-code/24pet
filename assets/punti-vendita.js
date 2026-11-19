// Punti vendita 24Pet: caricamento, ricerca e raggruppamento per regione e provincia.
// Usato dalla home (anteprima di 6) e dalla pagina /punti-vendita/ (elenco completo).
(() => {
    const API = 'https://vacxudtbzpfygkkxmhyz.supabase.co/rest/v1/public_resellers?select=name,kind,address,city,province,phone,mobile,email,website&order=province.asc,city.asc,name.asc';
    const KEY = 'sb_publishable_Pxz4_0wKSdVx4_sHoyhJlw_jfMSJid8';
    const P = {
        AQ: ["L’Aquila", 'Abruzzo'], CH: ['Chieti', 'Abruzzo'], PE: ['Pescara', 'Abruzzo'], TE: ['Teramo', 'Abruzzo'],
        MT: ['Matera', 'Basilicata'], PZ: ['Potenza', 'Basilicata'],
        CZ: ['Catanzaro', 'Calabria'], CS: ['Cosenza', 'Calabria'], KR: ['Crotone', 'Calabria'], RC: ['Reggio Calabria', 'Calabria'], VV: ['Vibo Valentia', 'Calabria'],
        AV: ['Avellino', 'Campania'], BN: ['Benevento', 'Campania'], CE: ['Caserta', 'Campania'], NA: ['Napoli', 'Campania'], SA: ['Salerno', 'Campania'],
        BO: ['Bologna', 'Emilia-Romagna'], FE: ['Ferrara', 'Emilia-Romagna'], FC: ['Forlì-Cesena', 'Emilia-Romagna'], MO: ['Modena', 'Emilia-Romagna'], PR: ['Parma', 'Emilia-Romagna'], PC: ['Piacenza', 'Emilia-Romagna'], RA: ['Ravenna', 'Emilia-Romagna'], RE: ['Reggio Emilia', 'Emilia-Romagna'], RN: ['Rimini', 'Emilia-Romagna'],
        GO: ['Gorizia', 'Friuli-Venezia Giulia'], PN: ['Pordenone', 'Friuli-Venezia Giulia'], TS: ['Trieste', 'Friuli-Venezia Giulia'], UD: ['Udine', 'Friuli-Venezia Giulia'],
        FR: ['Frosinone', 'Lazio'], LT: ['Latina', 'Lazio'], RI: ['Rieti', 'Lazio'], RM: ['Roma', 'Lazio'], VT: ['Viterbo', 'Lazio'],
        GE: ['Genova', 'Liguria'], IM: ['Imperia', 'Liguria'], SP: ['La Spezia', 'Liguria'], SV: ['Savona', 'Liguria'],
        BG: ['Bergamo', 'Lombardia'], BS: ['Brescia', 'Lombardia'], CO: ['Como', 'Lombardia'], CR: ['Cremona', 'Lombardia'], LC: ['Lecco', 'Lombardia'], LO: ['Lodi', 'Lombardia'], MN: ['Mantova', 'Lombardia'], MI: ['Milano', 'Lombardia'], MB: ['Monza e Brianza', 'Lombardia'], PV: ['Pavia', 'Lombardia'], SO: ['Sondrio', 'Lombardia'], VA: ['Varese', 'Lombardia'],
        AN: ['Ancona', 'Marche'], AP: ['Ascoli Piceno', 'Marche'], FM: ['Fermo', 'Marche'], MC: ['Macerata', 'Marche'], PU: ['Pesaro e Urbino', 'Marche'],
        CB: ['Campobasso', 'Molise'], IS: ['Isernia', 'Molise'],
        AL: ['Alessandria', 'Piemonte'], AT: ['Asti', 'Piemonte'], BI: ['Biella', 'Piemonte'], CN: ['Cuneo', 'Piemonte'], NO: ['Novara', 'Piemonte'], TO: ['Torino', 'Piemonte'], VB: ['Verbano-Cusio-Ossola', 'Piemonte'], VC: ['Vercelli', 'Piemonte'],
        BA: ['Bari', 'Puglia'], BT: ['Barletta-Andria-Trani', 'Puglia'], BR: ['Brindisi', 'Puglia'], FG: ['Foggia', 'Puglia'], LE: ['Lecce', 'Puglia'], TA: ['Taranto', 'Puglia'],
        CA: ['Cagliari', 'Sardegna'], NU: ['Nuoro', 'Sardegna'], OR: ['Oristano', 'Sardegna'], SS: ['Sassari', 'Sardegna'], SU: ['Sud Sardegna', 'Sardegna'], OT: ['Gallura Nord-Est Sardegna', 'Sardegna'], OG: ['Ogliastra', 'Sardegna'], VS: ['Medio Campidano', 'Sardegna'], CI: ['Sulcis Iglesiente', 'Sardegna'],
        AG: ['Agrigento', 'Sicilia'], CL: ['Caltanissetta', 'Sicilia'], CT: ['Catania', 'Sicilia'], EN: ['Enna', 'Sicilia'], ME: ['Messina', 'Sicilia'], PA: ['Palermo', 'Sicilia'], RG: ['Ragusa', 'Sicilia'], SR: ['Siracusa', 'Sicilia'], TP: ['Trapani', 'Sicilia'],
        AR: ['Arezzo', 'Toscana'], FI: ['Firenze', 'Toscana'], GR: ['Grosseto', 'Toscana'], LI: ['Livorno', 'Toscana'], LU: ['Lucca', 'Toscana'], MS: ['Massa-Carrara', 'Toscana'], PI: ['Pisa', 'Toscana'], PO: ['Prato', 'Toscana'], PT: ['Pistoia', 'Toscana'], SI: ['Siena', 'Toscana'],
        BZ: ['Bolzano', 'Trentino-Alto Adige'], TN: ['Trento', 'Trentino-Alto Adige'],
        PG: ['Perugia', 'Umbria'], TR: ['Terni', 'Umbria'],
        AO: ['Aosta', 'Valle d’Aosta'],
        BL: ['Belluno', 'Veneto'], PD: ['Padova', 'Veneto'], RO: ['Rovigo', 'Veneto'], TV: ['Treviso', 'Veneto'], VE: ['Venezia', 'Veneto'], VR: ['Verona', 'Veneto'], VI: ['Vicenza', 'Veneto']
    };
    const KINDS = { agenzia: 'Agenzia funebre', crematorio: 'Centro di cremazione', altro: 'Punto vendita' };
    const norm = v => String(v || '').toLowerCase().normalize('NFD').replace(/[̀-ͯ]/g, '').replace(/[’']/g, ' ');
    const coll = new Intl.Collator('it', { sensitivity: 'base' });

    function enrich(s) {
        const sigla = String(s.province || '').toUpperCase();
        const info = P[sigla];
        return Object.assign({}, s, {
            sigla,
            provinceName: info ? info[0] : (sigla || 'Altre località'),
            region: info ? info[1] : 'Altre località'
        });
    }
    async function load() {
        const r = await fetch(API, { headers: { apikey: KEY } });
        if (!r.ok) throw new Error('stores');
        const rows = await r.json();
        return (Array.isArray(rows) ? rows : []).map(enrich);
    }
    function matches(s, query) {
        const q = norm(query.trim());
        if (!q) return true;
        const hay = norm([s.name, s.city, s.sigla, s.provinceName, s.region, s.address].join(' '));
        return q.split(/\s+/).every(part => hay.includes(part));
    }
    function group(stores) {
        const regions = new Map();
        for (const s of stores) {
            if (!regions.has(s.region)) regions.set(s.region, new Map());
            const provs = regions.get(s.region);
            const key = s.provinceName;
            if (!provs.has(key)) provs.set(key, []);
            provs.get(key).push(s);
        }
        return [...regions].sort((a, b) => (a[0] === 'Altre località') - (b[0] === 'Altre località') || coll.compare(a[0], b[0]))
            .map(([region, provs]) => ({
                region,
                count: [...provs.values()].reduce((n, l) => n + l.length, 0),
                provinces: [...provs].sort((a, b) => coll.compare(a[0], b[0]))
                    .map(([name, list]) => ({ name, sigla: list[0].sigla, stores: list.sort((a, b) => coll.compare(a.city, b.city) || coll.compare(a.name, b.name)) }))
            }));
    }
    function link(href, text) {
        const a = document.createElement('a');
        a.href = href; a.textContent = text;
        if (/^https?:/.test(href)) { a.target = '_blank'; a.rel = 'noopener'; }
        return a;
    }
    function card(s, headingTag) {
        const li = document.createElement('li');
        li.className = 'store';
        const kind = document.createElement('p'); kind.className = 'store-kind'; kind.textContent = KINDS[s.kind] || KINDS.altro;
        const name = document.createElement(headingTag || 'h3'); name.className = 'store-name'; name.textContent = s.name;
        const place = document.createElement('p'); place.className = 'store-place';
        place.textContent = [s.address, [s.city, s.sigla ? '(' + s.sigla + ')' : ''].filter(Boolean).join(' ')].filter(Boolean).join(' · ');
        li.append(kind, name, place);
        const contacts = document.createElement('p'); contacts.className = 'store-contacts';
        if (s.phone) contacts.append(link('tel:' + s.phone.replace(/[^+\d]/g, ''), s.phone));
        if (s.mobile && s.mobile !== s.phone) contacts.append(link('tel:' + s.mobile.replace(/[^+\d]/g, ''), s.mobile));
        if (s.email) contacts.append(link('mailto:' + s.email, s.email));
        if (s.website && /^https?:\/\/[^\s]+$/i.test(s.website)) contacts.append(link(s.website, s.website.replace(/^https?:\/\/(www\.)?/, '').replace(/\/$/, '')));
        if (contacts.childNodes.length) li.append(contacts);
        return li;
    }
    function slug(t) { return 'regione-' + norm(t).replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, ''); }
    // Elenco raggruppato: regione (h2/h3) > provincia > schede
    function renderGrouped(container, stores, opts = {}) {
        const level = opts.level || 2;
        const groups = group(stores);
        container.replaceChildren(...groups.map(g => {
            const section = document.createElement('section');
            section.className = 'stores-region';
            section.id = slug(g.region);
            const h = document.createElement('h' + level);
            h.className = 'stores-region-title';
            h.append(document.createTextNode(g.region + ' '));
            const n = document.createElement('span'); n.textContent = g.count; n.setAttribute('aria-label', g.count + (g.count === 1 ? ' punto vendita' : ' punti vendita'));
            h.append(n);
            const provinces = document.createElement('div');
            provinces.className = 'stores-provinces';
            for (const p of g.provinces) {
                const box = document.createElement('div');
                box.className = 'stores-province';
                const ph = document.createElement('h' + (level + 1));
                ph.className = 'stores-province-title';
                ph.textContent = p.name === 'Altre località' ? p.name : 'Provincia di ' + p.name;
                const ul = document.createElement('ul');
                ul.className = 'stores-list';
                ul.setAttribute('role', 'list');
                ul.append(...p.stores.map(s => card(s, 'h' + Math.min(level + 2, 6))));
                box.append(ph, ul);
                provinces.append(box);
            }
            section.append(h, provinces);
            return section;
        }));
        return groups;
    }
    function shuffle(list) {
        const a = list.slice();
        for (let i = a.length - 1; i > 0; i--) { const j = Math.floor(Math.random() * (i + 1)); [a[i], a[j]] = [a[j], a[i]]; }
        return a;
    }
    window.PetStores = { load, matches, group, card, renderGrouped, shuffle, slug, norm };
})();
