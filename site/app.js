(() => {
  "use strict";
  const data = window.BENCHMARK_RESULTS;
  if (!data) return;
  const rows = data.rows, names = data.names;
  const metric = document.querySelector("#metric"), bars = document.querySelector("#bars");
  const definitions = {
    streamingTokensPerSecond: {unit:"tokens/s",digits:1,note:"Higher is faster. Nominal turns with at least eight generated tokens only. Labels show eligible throughput samples. Tokenizers differ across models."},
    firstTextSeconds: {unit:"s",digits:3,note:"Lower is faster. Median until first text, including prompt preparation and detokenization. Labels show eligible nominal turns."},
    peakProcessMiB: {unit:"MiB",digits:1,note:"Whole-process footprint, not total CPU-plus-GPU memory. Labels show wholly nominal conversations. Values based on one conversation are especially limited."},
    factual: {unit:"%",digits:0,note:"Diagnostic recall of one repeated synthetic conversation. Bars show correct/scorable probes, with nine planned per backend. Missing headline probes are thermal exclusions."}
  };
  function value(row,key) {return key === "factual" ? Number(row.factualProbesCorrect)/Number(row.factualProbesScorable)*100 : Number(row[key]);}
  function count(row,key) {
    const d = data.denominators.find(v => v.model === row.model && v.runtime === row.runtime);
    if (key === "streamingTokensPerSecond") return `n=${d.throughputSamples}/18`;
    if (key === "peakProcessMiB") return `n=${d.memoryConversations}/3`;
    if (key === "factual") return `${row.factualProbesCorrect}/${row.factualProbesScorable}; 9 planned`;
    return `n=${row.nominalSamples}/18`;
  }
  function renderBars() {
    const key=metric.value, definition=definitions[key];
    const max=key === "factual" ? 100 : Math.max(...rows.map(r=>value(r,key)))*1.08;
    bars.replaceChildren();
    for (const model of [...new Set(rows.map(r=>r.model))]) {
      const group=document.createElement("div");group.className="bar-model";
      const name=document.createElement("div");name.className="bar-name";name.textContent=names[model];
      const quant=document.createElement("small");quant.textContent=model === "qwen3-1.7b" ? "Q8_0" : "Q4_K_M";name.append(quant);group.append(name);
      const pair=document.createElement("div");pair.className="bar-pair";
      for (const row of rows.filter(r=>r.model===model)) {
        const backend=row.runtime.split(" ").at(-1), line=document.createElement("div");line.className="bar-line";
        const label=document.createElement("span");label.textContent=backend;
        const track=document.createElement("div");track.className="bar-track";track.setAttribute("aria-hidden","true");
        const bar=document.createElement("span");bar.className="bar "+backend.toLowerCase();bar.style.setProperty("--width",`${value(row,key)/max*100}%`);track.append(bar);
        const number=document.createElement("span");number.className="bar-value";number.textContent=`${value(row,key).toFixed(definition.digits)} ${definition.unit} · ${count(row,key)}`;
        line.append(label,track,number);pair.append(line);
      }
      group.append(pair);bars.append(group);
    }
    document.querySelector("#metric-note").textContent=definition.note;
    document.querySelector("#chart-scale").textContent=`All bars share a zero baseline. Scale: 0 to ${max.toFixed(definition.digits)} ${definition.unit}. Exact values and coverage appear beside every bar.`;
    bars.setAttribute("aria-label",`${metric.selectedOptions[0].textContent}. CPU and Metal values and eligible sample counts are listed for each model.`);
  }
  const modelSelect=document.querySelector("#history-model");
  function renderHistory() {
    const model=modelSelect.value, part=data.turns.filter(r=>r.model===model);
    const container=document.querySelector("#history-plot");
    const W=800,H=280,left=62,right=26,top=28,bottom=45;
    const max=Math.max(...part.map(r=>Number(r.firstTextSeconds || 0)))*1.12;
    const x=t=>left+(Number(t)-1)*(W-left-right)/5, y=v=>H-bottom-Number(v)/max*(H-top-bottom);
    const ns="http://www.w3.org/2000/svg", svg=document.createElementNS(ns,"svg");
    svg.setAttribute("viewBox",`0 0 ${W} ${H}`);svg.setAttribute("role","img");
    svg.setAttribute("aria-label",`${names[model]} first text in seconds over six turns. CPU is dashed; Metal is solid. The table below gives values and sample counts.`);
    function add(tag,attrs,text) {const el=document.createElementNS(ns,tag);for(const [k,v] of Object.entries(attrs))el.setAttribute(k,v);if(text!==undefined)el.textContent=text;svg.append(el);return el;}
    for(let i=0;i<=4;i++) {const v=max*i/4;add("line",{x1:left,x2:W-right,y1:y(v),y2:y(v),stroke:"var(--line)"});add("text",{x:left-10,y:y(v)+4,"text-anchor":"end"},v.toFixed(1));}
    add("text",{x:left,y:18},"First text, seconds");
    for(let t=1;t<=6;t++)add("text",{x:x(t),y:H-18,"text-anchor":"middle"},`Turn ${t}`);
    for(const backend of ["CPU","Metal"]) {
      const points=part.filter(r=>r.runtime.endsWith(backend)&&r.firstTextSeconds!=="");
      add("polyline",{points:points.map(r=>`${x(r.turn)},${y(r.firstTextSeconds)}`).join(" "),fill:"none",stroke:`var(--${backend.toLowerCase()})`,"stroke-width":3,"stroke-dasharray":backend==="CPU"?"7 5":"none"});
      for(const p of points) {const dot=add("circle",{cx:x(p.turn),cy:y(p.firstTextSeconds),r:4,fill:`var(--${backend.toLowerCase()})`});const title=document.createElementNS(ns,"title");title.textContent=`${backend}, turn ${p.turn}: ${Number(p.firstTextSeconds).toFixed(3)} s, n=${p.nominalSamples}`;dot.append(title);}
    }
    container.replaceChildren(svg);
    const wrapper=document.querySelector("#history-table"), table=document.createElement("table");
    const caption=document.createElement("caption");caption.textContent=`${names[model]}: first text in seconds (nominal n). CPU dashed, Metal solid in the chart.`;table.append(caption);
    const header=document.createElement("thead"), hr=document.createElement("tr");
    for(const label of ["Backend","Turn 1","Turn 2","Turn 3","Turn 4","Turn 5","Turn 6"]){const th=document.createElement("th");th.scope="col";th.textContent=label;hr.append(th);}header.append(hr);table.append(header);
    const body=document.createElement("tbody");
    for(const backend of ["CPU","Metal"]) {const row=document.createElement("tr"),th=document.createElement("th");th.scope="row";th.textContent=backend;row.append(th);for(const p of part.filter(r=>r.runtime.endsWith(backend))){const td=document.createElement("td");td.textContent=p.firstTextSeconds===""?"No nominal samples":`${Number(p.firstTextSeconds).toFixed(3)} (n=${p.nominalSamples})`;row.append(td);}body.append(row);}table.append(body);wrapper.replaceChildren(table);
  }
  metric.addEventListener("change",renderBars);modelSelect.addEventListener("change",renderHistory);
  document.querySelector("#explorer").hidden=false;document.querySelector(".history-controls").hidden=false;document.querySelector("#history-plot").hidden=false;
  const theme=document.querySelector("#theme");theme.hidden=false;
  function setTheme(value){document.documentElement.dataset.theme=value;theme.textContent=value==="dark"?"Use light theme":"Use dark theme";}
  try {setTheme(localStorage.getItem("openweights-theme")==="dark"?"dark":"light");} catch {setTheme("light");}
  theme.addEventListener("click",()=>{const value=document.documentElement.dataset.theme==="dark"?"light":"dark";setTheme(value);try{localStorage.setItem("openweights-theme",value);}catch{}});
  renderBars();renderHistory();
})();
