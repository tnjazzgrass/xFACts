// ============================================================================
// xFACts Control Center - Administration Page JavaScript
// Location: E:\xFACts-ControlCenter\public\js\admin.js
// Version: Tracked in dbo.System_Metadata (component: ControlCenter.Admin)
// ============================================================================

// ============================================================================
// REFRESH ARCHITECTURE (Shared plumbing)
// ============================================================================

// ENGINE_PROCESSES: maps orchestrator process names to card slugs.
// Empty -- Administration uses its own process timeline visualization.
var ENGINE_PROCESSES = {};

// Midnight rollover check
var pageLoadDate = new Date().toDateString();
setInterval(function() {
    if (new Date().toDateString() !== pageLoadDate) window.location.reload();
}, 60000);

// Engine-events hooks (called by engine-events.js)
function onEngineProcessCompleted(processName, event) {
    // Admin uses onEngineEventRaw for all event handling — this hook is unused
}

// Raw event hook — receives ALL WebSocket events before ENGINE_PROCESSES filtering.
// This is the primary real-time data path for the Admin timeline and sidebar.
function onEngineEventRaw(event) {
    Admin.handleEngineEvent(event);
}

// ============================================================================
// ADMINISTRATION
// ============================================================================

// Page hooks for engine-events.js shared module
function onPageResumed() { Admin.pageRefresh(); }
function onSessionExpired() { /* Admin has no standalone polling timer */ }

const Admin = (function () {

    const SAFETY_NET_MS = 60000;
    const TICK_MS = 1000;
    const GRACE_SEC = 15;
    let processData = [], timelineData = [], lastRefresh = null;
    let processCountdowns = {};  // pid -> { countdown, lastCalc } — event-driven via calcCountdownFromEvent
    let isDraining = false, serviceStatus = 'Unknown', totalRunning = 0;
    let pendingConfirm = null, logData = { output: null, error: null };
    let activeFilter = 'all', windowMinutes = 30;
    let hoveredTask = null, selectedTask = null, canvasRows = [];
    let processOrder = [];
    const GROUP_H = 22, ROW_H = 30, MIN_BAR_W = 3;
    const MODULE_COLORS = {
        ServerOps:{bar:'#2563eb',light:'#60a5fa',glow:'rgba(37,99,235,0.3)'},
        JobFlow:{bar:'#7c3aed',light:'#a78bfa',glow:'rgba(124,58,237,0.3)'},
        BatchOps:{bar:'#d97706',light:'#fbbf24',glow:'rgba(217,119,6,0.3)'},
        FileOps:{bar:'#059669',light:'#34d399',glow:'rgba(5,150,105,0.3)'},
        DeptOps:{bar:'#db2777',light:'#f472b6',glow:'rgba(219,39,119,0.3)'},
        Orchestrator:{bar:'#4ec9b0',light:'#4ec9b0',glow:'rgba(78,201,176,0.3)'},
        Teams:{bar:'#0ea5e9',light:'#38bdf8',glow:'rgba(14,165,233,0.3)'},
        Jira:{bar:'#f97316',light:'#fb923c',glow:'rgba(249,115,22,0.3)'}
    };
    const DEFAULT_COLOR={bar:'#888',light:'#aaa',glow:'rgba(136,136,136,0.3)'};
    function getModColor(m){return MODULE_COLORS[m]||DEFAULT_COLOR;}
    const STATUS_COLORS={SUCCESS:null,RUNNING:{bar:'#569cd6',light:'#7dc4ff'},LAUNCHED:{bar:'#569cd6',light:'#7dc4ff'},FAILED:{bar:'#ef4444',light:'#f87171'},TIMEOUT:{bar:'#f87171',light:'#fca5a5'},POLLING:{bar:'#dcdcaa',light:'#e8e8c0'}};
    const GROUP_LABELS={10:'Collectors',20:'Processors',30:'Scanners & Dept',99:'Queue Processors'};

    function init(){
        // Initial data load (one-time, seeds the page)
        loadDrainStatus();loadProcessStatus();loadTimelineData();loadAlertFailureCount();
        // 60-second safety-net refresh — sidebar data (status, countdowns, daily counts)
        // Timeline is driven entirely by WebSocket events + initial load
        setInterval(function(){if(enginePageHidden||engineSessionExpired)return;loadProcessStatus();loadDrainStatus();loadAlertFailureCount();},SAFETY_NET_MS);
        // 1-second tick: advance countdowns + repaint canvas (smooth NOW line, growing bars)
        setInterval(tickAll,TICK_MS);
        window.addEventListener('resize',function(){layoutAndPaint();});
        var cv=document.getElementById('timeline-canvas');
        cv.addEventListener('mousemove',onCanvasMouseMove);cv.addEventListener('mouseleave',onCanvasMouseLeave);cv.addEventListener('click',onCanvasClick);
        connectEngineEvents();
        initEngineCardClicks();
        // Wire up doc pipeline sub-option visibility toggles
        initDocStepToggles();
    }

    function pageRefresh(){
        var btn=document.querySelector('.page-refresh-btn');
        if(btn){btn.classList.add('spinning');btn.addEventListener('animationend',function(){btn.classList.remove('spinning');},{once:true});}
        loadDrainStatus();loadProcessStatus();loadTimelineData();loadAlertFailureCount();
    }

    // ================================================================
    // WEBSOCKET EVENT HANDLER (real-time timeline + sidebar updates)
    // Called by onEngineEventRaw() for every orchestrator event.
    // ================================================================
    function handleEngineEvent(event) {
        if (!processData.length) return;  // Not yet initialized

        var procName = event.processName;
        var proc = null;
        for (var i = 0; i < processData.length; i++) {
            if (processData[i].process_name === procName) { proc = processData[i]; break; }
        }
        if (!proc) return;  // Unknown process (new since page load — safety net will pick it up)

        if (event.eventType === 'PROCESS_STARTED') {
            // Update sidebar state
            proc.running_count = (proc.running_count || 0) + 1;
            proc.last_execution_status = 'RUNNING';
            // Clear countdown while running
            delete processCountdowns[proc.process_id];

            // Add an open-ended bar to the timeline
            timelineData.push({
                task_id: event.taskId || ('ws-' + Date.now()),
                process_id: event.processId,
                process_name: procName,
                module_name: event.moduleName,
                dependency_group: proc.dependency_group,
                execution_mode: proc.execution_mode,
                task_status: 'RUNNING',
                start_dttm: event.timestamp,
                end_dttm: null,
                duration_ms: null,
                output_summary: null,
                error_output: null
            });

            renderSidebar();
        }
        else if (event.eventType === 'PROCESS_COMPLETED') {
            // Update sidebar state
            proc.running_count = Math.max((proc.running_count || 1) - 1, 0);
            proc.last_execution_status = event.status || 'SUCCESS';
            proc.last_duration_ms = event.durationMs;
            proc.last_execution_dttm = event.timestamp;

            // Update daily aggregates
            var st = (event.status || 'SUCCESS').toUpperCase();
            if (st === 'SUCCESS') proc.daily_success = (proc.daily_success || 0) + 1;
            else if (st === 'FAILED' || st === 'TIMEOUT') proc.daily_failed = (proc.daily_failed || 0) + 1;

            // Calculate countdown from event scheduling metadata
            var cd = calcCountdownFromEvent(event, Date.now());
            if (cd !== null) {
                processCountdowns[proc.process_id] = { countdown: cd, lastCalc: Date.now() };
            } else {
                delete processCountdowns[proc.process_id];
            }

            // Close the matching open bar in timeline data
            var closed = false;
            for (var j = timelineData.length - 1; j >= 0; j--) {
                var t = timelineData[j];
                if (t.process_name === procName && !t.end_dttm) {
                    t.end_dttm = event.timestamp;
                    t.duration_ms = event.durationMs;
                    t.task_status = event.status || 'SUCCESS';
                    t.output_summary = event.outputSummary || null;
                    if (event.taskId) t.task_id = event.taskId;
                    closed = true;
                    break;
                }
            }

            // If no open bar found (e.g. page loaded after STARTED), add a completed bar
            if (!closed && event.timestamp && event.durationMs) {
                var startMs = new Date(event.timestamp).getTime() - event.durationMs;
                timelineData.push({
                    task_id: event.taskId || ('ws-' + Date.now()),
                    process_id: event.processId,
                    process_name: procName,
                    module_name: event.moduleName,
                    dependency_group: proc.dependency_group,
                    execution_mode: proc.execution_mode,
                    task_status: event.status || 'SUCCESS',
                    start_dttm: new Date(startMs).toISOString(),
                    end_dttm: event.timestamp,
                    duration_ms: event.durationMs,
                    output_summary: event.outputSummary || null,
                    error_output: null
                });
            }

            renderSidebar();
        }
    }
    function buildLegend(){
        var el=document.getElementById('timeline-legend');
        if(!processData.length){el.innerHTML='';return;}
        var seen={},mods=[];
        processData.forEach(function(p){var m=p.module_name;if(m&&!seen[m]){seen[m]=1;mods.push(m);}});
        mods.sort();
        var html='';
        mods.forEach(function(m){
            var c=getModColor(m);
            html+='<span class="tl-legend-item"><span class="tl-legend-dot" style="background:'+c.bar+';"></span>'+m+'</span>';
        });el.innerHTML=html;
    }
    function loadProcessStatus(){
        engineFetch('/api/admin/process-status').then(function(data){ if(!data)return;
            if(data.Error){showErr(data.Error);return;}clearErr();
            processData=Array.isArray(data)?data:[];lastRefresh=Date.now();
            // Seed countdowns from API data (initial load and safety-net refresh)
            processData.forEach(function(p){
                var secs=p.seconds_until_next;
                if(secs!==null&&secs!==undefined){
                    processCountdowns[p.process_id]={countdown:secs,lastCalc:Date.now()};
                }
            });
            buildProcessOrder();buildLegend();renderSidebar();layoutAndPaint();updateTs();
        }).catch(function(e){showErr('API unreachable: '+e.message);});
    }
    function loadTimelineData(){
        engineFetch('/api/admin/timeline-data?window_minutes='+windowMinutes).then(function(data){ if(!data)return;
            if(data.Error)return;timelineData=Array.isArray(data)?data:[];layoutAndPaint();
        }).catch(function(){});
    }
    function buildProcessOrder(){
        var groups={};processData.forEach(function(p){var g=p.dependency_group;if(!groups[g])groups[g]=[];groups[g].push(p);});
        var gkeys=Object.keys(groups).sort(function(a,b){return +a - +b;});processOrder=[];
        gkeys.forEach(function(g){groups[g].sort(function(a,b){return a.process_name.localeCompare(b.process_name);});groups[g].forEach(function(p){processOrder.push(p);});});
    }
    function renderSidebar(){
        var sb=document.getElementById('timeline-sidebar');
        if(!processData.length){sb.innerHTML='<div class="loading">Loading...</div>';return;}
        var html='',lastGroup=null;
        processOrder.forEach(function(p){
            var st=resolveStatus(p),visible=matchesFilter(p,st);
            if(p.dependency_group!==lastGroup){lastGroup=p.dependency_group;html+='<div class="tl-group-header">'+(GROUP_LABELS[lastGroup]||('Group '+lastGroup))+'</div>';}
            if(!visible)return;
            var isE=p.run_mode!==0,pwrCls=isE?'on':'off',dotCls=st.toLowerCase(),rowCls='tl-process-row';
            if(!isE)rowCls+=' tl-disabled';if(st==='RUNNING'||st==='LAUNCHED')rowCls+=' tl-running';
            var cd=getCd(p),cdH='';
            if(cd!==null&&p.run_mode===1){if(cd< -GRACE_SEC)cdH='<span class="tl-countdown overdue" data-pid="'+p.process_id+'">'+fmtCd(cd)+'</span>';else if(cd>0)cdH='<span class="tl-countdown" data-pid="'+p.process_id+'">'+fmtCd(cd)+'</span>';else cdH='<span class="tl-countdown" data-pid="'+p.process_id+'"></span>';}
            else if(p.run_mode===2)cdH='<span class="tl-countdown queue">queue</span>';
            else if(p.run_mode===0)cdH='<span class="tl-countdown off">off</span>';
            var ds=p.daily_success||0,df=p.daily_failed||0;
            var ctsH='<span class="tl-counts"><span class="'+(ds>0?'tl-count-ok':'tl-count-zero')+'">'+ds+'</span><span class="'+(df>0?'tl-count-fail':'tl-count-zero')+'">'+df+'</span></span>';
            html+='<div class="'+rowCls+'" data-pid="'+p.process_id+'">'+'<button class="tl-pwr '+pwrCls+'" onclick="event.stopPropagation();Admin.toggleProcess('+p.process_id+','+(isE?'true':'false')+',\''+esc(p.process_name)+'\')" title="'+(isE?'Disable':'Enable')+' '+esc(p.process_name)+'">\u23FB</button>'+'<span class="tl-proc-badge '+dotCls+'" title="'+esc(p.process_name)+'">'+esc(p.process_name)+'</span>'+ctsH+cdH+'</div>';
        });
        sb.innerHTML=html;sb.onscroll=function(){paintCanvas();};
    }
    function resolveStatus(p){if(p.run_mode===0)return'DISABLED';if(p.running_count>0)return'RUNNING';var s=(p.last_execution_status||'SUCCESS').toUpperCase();if(['SUCCESS','FAILED','TIMEOUT','LAUNCHED','POLLING'].indexOf(s)===-1)s='SUCCESS';return s;}
    function matchesFilter(p,st){if(activeFilter==='all')return true;if(activeFilter==='running')return st==='RUNNING'||st==='LAUNCHED';if(activeFilter==='failed')return st==='FAILED'||st==='TIMEOUT'||(p.daily_failed&&p.daily_failed>0);return true;}
    function setFilter(f){activeFilter=f;document.querySelectorAll('.filter-pill').forEach(function(b){b.classList.toggle('active',b.getAttribute('data-filter')===f);});renderSidebar();layoutAndPaint();}
    function setWindow(m){windowMinutes=m;document.querySelectorAll('.window-btn').forEach(function(b){b.classList.toggle('active',+b.getAttribute('data-window')===m);});loadTimelineData();}
    function layoutAndPaint(){buildCanvasRows();paintCanvas();}
    function buildCanvasRows(){
        canvasRows=[];if(!processData.length)return;var y=0,lastGroup=null;
        processOrder.forEach(function(p){var st=resolveStatus(p);if(!matchesFilter(p,st))return;
            if(p.dependency_group!==lastGroup){lastGroup=p.dependency_group;canvasRows.push({type:'group',label:GROUP_LABELS[lastGroup]||('Group '+lastGroup),y:y,h:GROUP_H,group:lastGroup});y+=GROUP_H;}
            canvasRows.push({type:'process',label:p.process_name,processName:p.process_name,module:p.module_name,group:p.dependency_group,processId:p.process_id,y:y,h:ROW_H});y+=ROW_H;
        });
    }
    function paintCanvas(){
        var wrap=document.getElementById('timeline-canvas-wrap'),canvas=document.getElementById('timeline-canvas');if(!wrap||!canvas)return;
        var dpr=window.devicePixelRatio||1,w=wrap.clientWidth;
        var totalH=canvasRows.length>0?canvasRows[canvasRows.length-1].y+canvasRows[canvasRows.length-1].h:300;
        var h=Math.max(totalH,wrap.clientHeight);
        canvas.width=w*dpr;canvas.height=h*dpr;canvas.style.width=w+'px';canvas.style.height=h+'px';
        var ctx=canvas.getContext('2d');ctx.scale(dpr,dpr);ctx.clearRect(0,0,w,h);
        var sb=document.getElementById('timeline-sidebar'),scrollTop=sb?sb.scrollTop:0;
        ctx.save();ctx.translate(0,-scrollTop);
        var now=Date.now(),tStart=now-windowMinutes*60*1000,tEnd=now+2*60*1000;
        function tx(t){return((t-tStart)/(tEnd-tStart))*w;}
        canvasRows.forEach(function(row,i){if(row.type==='group'){ctx.fillStyle='#1a1a1e';ctx.fillRect(0,row.y,w,row.h);}else{ctx.fillStyle=i%2===0?'#252526':'#282830';ctx.fillRect(0,row.y,w,row.h);}});
        var gi;if(windowMinutes<=15)gi=60000;else if(windowMinutes<=30)gi=300000;else gi=600000;
        var fg=Math.ceil(tStart/gi)*gi;ctx.strokeStyle='rgba(255,255,255,0.04)';ctx.lineWidth=1;ctx.font='10px "Segoe UI",sans-serif';ctx.fillStyle='#444';ctx.textBaseline='top';
        for(var gt=fg;gt<=tEnd;gt+=gi){var gx=tx(gt);ctx.beginPath();ctx.moveTo(gx,0);ctx.lineTo(gx,h);ctx.stroke();var gd=new Date(gt);ctx.fillText(gd.getHours()+':'+(gd.getMinutes()<10?'0':'')+gd.getMinutes(),gx+3,3);}
        var nx=tx(now);ctx.strokeStyle='rgba(78,201,176,0.5)';ctx.lineWidth=1.5;ctx.setLineDash([6,4]);ctx.beginPath();ctx.moveTo(nx,0);ctx.lineTo(nx,h);ctx.stroke();ctx.setLineDash([]);
        ctx.fillStyle='#4ec9b0';ctx.font='600 9px "Segoe UI",sans-serif';ctx.textBaseline='bottom';ctx.fillText('NOW',nx+3,canvasRows.length>0?canvasRows[0].y+canvasRows[0].h-2:18);
        var prm={};canvasRows.forEach(function(r){if(r.type==='process')prm[r.processName]=r;});
        timelineData.forEach(function(task){
            var row=prm[task.process_name];if(!row)return;
            var sd=parseDate(task.start_dttm);if(!sd)return;var sT=sd.getTime(),eT;
            if(task.end_dttm){var ed=parseDate(task.end_dttm);eT=ed?ed.getTime():sT+(task.duration_ms||1000);}else{eT=now;}
            var x1=tx(sT),x2=tx(eT),bW=Math.max(x2-x1,MIN_BAR_W);if(x1+bW<0||x1>w)return;
            var bY=row.y+4,bH=row.h-8,st=(task.task_status||'SUCCESS').toUpperCase();
            var sc=STATUS_COLORS[st],mc=getModColor(task.module_name);
            var fc=sc?sc.bar:mc.bar,lc=sc?sc.light:mc.light;
            var isH=hoveredTask&&hoveredTask.task_id===task.task_id,isS=selectedTask&&selectedTask.task_id===task.task_id;
            if(isH||isS){ctx.shadowColor=sc?sc.bar:mc.glow;ctx.shadowBlur=8;}
            var gr=ctx.createLinearGradient(x1,bY,x1,bY+bH);gr.addColorStop(0,lc);gr.addColorStop(1,fc);ctx.fillStyle=gr;
            var rr=Math.min(3,bH/2);rrect(ctx,x1,bY,bW,bH,rr);ctx.fill();ctx.shadowColor='transparent';ctx.shadowBlur=0;
            if(bW>50){ctx.fillStyle='rgba(0,0,0,0.6)';ctx.font='600 8px "Segoe UI",sans-serif';ctx.textBaseline='middle';ctx.fillText(fmtDur(task.duration_ms),x1+4,bY+bH/2);}
            if(isS){ctx.strokeStyle='#fff';ctx.lineWidth=1.5;rrect(ctx,x1,bY,bW,bH,rr);ctx.stroke();}
        });
        ctx.restore();
    }
    function rrect(ctx,x,y,w,h,r){ctx.beginPath();ctx.moveTo(x+r,y);ctx.lineTo(x+w-r,y);ctx.arcTo(x+w,y,x+w,y+r,r);ctx.lineTo(x+w,y+h-r);ctx.arcTo(x+w,y+h,x+w-r,y+h,r);ctx.lineTo(x+r,y+h);ctx.arcTo(x,y+h,x,y+h-r,r);ctx.lineTo(x,y+r);ctx.arcTo(x,y,x+r,y,r);}
    function getTaskAtPoint(cx,cy){
        if(!timelineData.length||!canvasRows.length)return null;
        var wrap=document.getElementById('timeline-canvas-wrap'),w=wrap.clientWidth;
        var sb=document.getElementById('timeline-sidebar'),st=sb?sb.scrollTop:0,aY=cy+st;
        var now=Date.now(),tS=now-windowMinutes*60*1000,tE=now+2*60*1000;
        function tx(t){return((t-tS)/(tE-tS))*w;}
        var prm={};canvasRows.forEach(function(r){if(r.type==='process')prm[r.processName]=r;});
        for(var i=timelineData.length-1;i>=0;i--){
            var task=timelineData[i],row=prm[task.process_name];if(!row)continue;
            var sd=parseDate(task.start_dttm);if(!sd)continue;var sT=sd.getTime(),eT;
            if(task.end_dttm){var ed=parseDate(task.end_dttm);eT=ed?ed.getTime():sT+(task.duration_ms||1000);}else{eT=now;}
            var x1=tx(sT),x2=tx(eT),bW=Math.max(x2-x1,MIN_BAR_W),bY=row.y+4,bH=row.h-8;
            if(cx>=x1&&cx<=x1+bW&&aY>=bY&&aY<=bY+bH)return task;
        }return null;
    }
    function onCanvasMouseMove(e){var r=e.target.getBoundingClientRect(),x=e.clientX-r.left,y=e.clientY-r.top;var t=getTaskAtPoint(x,y);var ch=(hoveredTask?hoveredTask.task_id:null)!==(t?t.task_id:null);hoveredTask=t;if(ch){paintCanvas();if(t)showTooltip(t,e.clientX,e.clientY);else hideTooltip();}else if(t){positionTooltip(e.clientX,e.clientY);}e.target.style.cursor=t?'pointer':'default';}
    function onCanvasMouseLeave(){if(hoveredTask){hoveredTask=null;paintCanvas();hideTooltip();}}
    function onCanvasClick(e){var r=e.target.getBoundingClientRect(),t=getTaskAtPoint(e.clientX-r.left,e.clientY-r.top);if(t){selectedTask=t;paintCanvas();openLogFromTask(t);}else if(selectedTask){selectedTask=null;paintCanvas();}}
    function showTooltip(task,cx,cy){
        var el=document.getElementById('tl-tooltip'),st=(task.task_status||'SUCCESS').toUpperCase();
        el.innerHTML='<div class="tl-tooltip-name">'+esc(task.process_name)+'</div>'+'<div class="tl-tooltip-row"><span class="tl-tooltip-label">Status</span><span class="tl-tooltip-status '+st.toLowerCase()+'">'+st+'</span></div>'+'<div class="tl-tooltip-row"><span class="tl-tooltip-label">Started</span><span class="tl-tooltip-value">'+fmtTs(task.start_dttm)+'</span></div>'+'<div class="tl-tooltip-row"><span class="tl-tooltip-label">Duration</span><span class="tl-tooltip-value">'+fmtDur(task.duration_ms)+'</span></div>'+'<div class="tl-tooltip-row"><span class="tl-tooltip-label">Mode</span><span class="tl-tooltip-value">'+esc(task.execution_mode||'-')+'</span></div>'+'<div class="tl-tooltip-row"><span class="tl-tooltip-label">Task ID</span><span class="tl-tooltip-value">#'+task.task_id+'</span></div>';
        el.classList.add('visible');positionTooltip(cx,cy);
    }
    function positionTooltip(cx,cy){var el=document.getElementById('tl-tooltip'),tw=el.offsetWidth||280,th=el.offsetHeight||120,px=cx+12,py=cy-th-8;if(px+tw>window.innerWidth-10)px=cx-tw-12;if(py<10)py=cy+16;el.style.left=px+'px';el.style.top=py+'px';}
    function hideTooltip(){document.getElementById('tl-tooltip').classList.remove('visible');}
    function openLogFromTask(task){logData.output=task.output_summary||null;logData.error=task.error_output||null;document.getElementById('log-modal-title').textContent='Task #'+task.task_id+'  \u2502  '+fmtTs(task.start_dttm)+'  \u2502  '+(task.task_status||'?');var ot=document.getElementById('log-tab-output'),et=document.getElementById('log-tab-error');ot.className='log-tab active'+(logData.output?' has-content':'');et.className='log-tab'+(logData.error?' has-error':'');showLogContent('output');document.getElementById('log-overlay').classList.add('visible');}
    function closeLog(){document.getElementById('log-overlay').classList.remove('visible');}
    function switchLogTab(tab){document.getElementById('log-tab-output').classList.toggle('active',tab==='output');document.getElementById('log-tab-error').classList.toggle('active',tab==='error');showLogContent(tab);}
    function showLogContent(tab){var el=document.getElementById('log-content'),txt=tab==='error'?logData.error:logData.output;if(txt&&txt.trim()){el.textContent=txt;el.className='log-content'+(tab==='error'?' error-text':'');}else{el.textContent=tab==='error'?'No error output':'No output captured';el.className='log-content empty';}}
    function getCd(p){if(p.run_mode===0||p.run_mode===2)return null;var entry=processCountdowns[p.process_id];if(!entry)return null;var elapsed=Math.floor((Date.now()-entry.lastCalc)/1000);return entry.countdown-elapsed;}
    function tickCountdowns(){if(!processData.length)return;document.querySelectorAll('.tl-countdown[data-pid]').forEach(function(sp){var pid=+sp.getAttribute('data-pid'),entry=processCountdowns[pid];if(!entry)return;var cur=entry.countdown-Math.floor((Date.now()-entry.lastCalc)/1000);if(cur< -GRACE_SEC){sp.textContent=fmtCd(cur);sp.classList.add('overdue');}else if(cur>0){sp.textContent=fmtCd(cur);sp.classList.remove('overdue');}else{sp.textContent='';sp.classList.remove('overdue');}});}
    function tickAll(){if(enginePageHidden||engineSessionExpired)return;tickCountdowns();paintCanvas();}
    function fmtCd(s){if(s===null)return'';var neg=s<0,a=Math.abs(Math.floor(s)),m=Math.floor(a/60),sec=a%60,d;if(m>60){var h=Math.floor(m/60);d=h+'h '+(m%60)+'m';}else if(m>0){d=m+':'+(sec<10?'0':'')+sec;}else{d=sec+'s';}return neg?'+'+d:d;}
    function loadDrainStatus(){engineFetch('/api/admin/drain-status').then(function(d){ if(!d)return;if(!d.Error){isDraining=d.drain_mode===1;serviceStatus=d.service_status||'Unknown';totalRunning=d.total_running||0;renderDrain();renderEnginePip();}}).catch(function(){});}
    function renderEnginePip(){var ep=document.getElementById('engine-pip'),sp=document.getElementById('service-pip');if(ep){ep.classList.remove('draining');if(isDraining)ep.classList.add('draining');}if(sp){sp.classList.remove('stopped','pending');if(serviceStatus==='Stopped')sp.classList.add('stopped');else if(serviceStatus==='StopPending'||serviceStatus==='StartPending')sp.classList.add('pending');}}
    function openEngineControls(){document.getElementById('engine-backdrop').classList.add('visible');document.getElementById('engine-panel').classList.add('visible');loadDrainStatus();}
    function closeEngineControls(){document.getElementById('engine-backdrop').classList.remove('visible');document.getElementById('engine-panel').classList.remove('visible');}
    function renderDrain(){var h=document.getElementById('switch-handle'),l=document.getElementById('status-light'),s=document.getElementById('drain-status');if(!h)return;if(!isDraining){h.className='switch-handle on';l.className='status-light online';s.className='drain-status online';s.textContent='ONLINE';}else if(serviceStatus==='StopPending'){h.className='switch-handle off';l.className='status-light caution';s.className='drain-status caution';s.textContent='STOPPING';}else if(serviceStatus==='StartPending'){h.className='switch-handle off';l.className='status-light caution';s.className='drain-status caution';s.textContent='RESTARTING';}else if(totalRunning>0&&serviceStatus==='Running'){h.className='switch-handle off';l.className='status-light caution';s.className='drain-status caution';s.textContent='DRAINING';}else{h.className='switch-handle off';l.className='status-light offline';s.className='drain-status offline';s.textContent='OFFLINE';}var plate=document.querySelector('.breaker-plate');if(plate)plate.classList.toggle('drain-warning',isDraining&&totalRunning===0&&serviceStatus==='Running');renderServiceBadge();renderServiceButtons();renderGuidance();}
    function renderServiceBadge(){var b=document.getElementById('svc-badge');if(!b)return;b.classList.remove('svc-running','svc-stopped','svc-pending','svc-unknown');switch(serviceStatus){case'Running':b.textContent='SERVICE RUNNING';b.classList.add('svc-running');break;case'Stopped':b.textContent='SERVICE STOPPED';b.classList.add('svc-stopped');break;case'StartPending':case'StopPending':b.textContent='SERVICE '+serviceStatus.toUpperCase();b.classList.add('svc-pending');break;default:b.textContent='SERVICE '+serviceStatus.toUpperCase();b.classList.add('svc-unknown');break;}}
    function renderServiceButtons(){var bs=document.getElementById('svc-btn-stop'),bt=document.getElementById('svc-btn-start'),br=document.getElementById('svc-btn-restart');if(!bs)return;bs.disabled=true;bt.disabled=true;br.disabled=true;if(serviceStatus==='Stopped'){bt.disabled=false;return;}if(!isDraining)return;if(totalRunning===0&&serviceStatus==='Running'){bs.disabled=false;br.disabled=false;}}
    function renderGuidance(){var g=document.getElementById('svc-guidance');if(!g)return;var msg='';if(serviceStatus==='StartPending'||serviceStatus==='StopPending'){msg='<span class="guidance-muted">Service state is changing. Please wait...</span>';}else if(!isDraining&&serviceStatus==='Running'){msg='<span class="guidance-muted">Normal operations.</span> To perform maintenance, engage drain mode first.';}else if(isDraining&&serviceStatus==='Running'&&totalRunning>0){msg='Waiting for <span class="guidance-step">'+totalRunning+' running process'+(totalRunning>1?'es':'')+' to complete</span> before the service can be stopped.';}else if(isDraining&&serviceStatus==='Running'&&totalRunning===0){msg='All processes drained. <span class="guidance-step">Stop</span> or <span class="guidance-step">Restart</span> the service when ready.';}else if(isDraining&&serviceStatus==='Stopped'){msg='Service is stopped. <span class="guidance-step">Disengage drain mode</span> above, then click <span class="guidance-step">Start</span> for a clean startup.';}else if(!isDraining&&serviceStatus==='Stopped'){msg='Ready. Click <span class="guidance-step">Start</span> to resume normal operations.';}else{msg='';}g.innerHTML=msg;}
    function toggleDrain(){if(!isDraining)showConfirm('Engage Drain Mode','Stop launching new processes. Running processes complete normally.','Engage','danger',function(){postDrain(1);});else showConfirm('Resume Operations','Re-enable normal orchestrator operations.','Resume','safe',function(){postDrain(0);});}
    function postDrain(v){engineFetch('/api/admin/drain-mode',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({drain_mode:v})}).then(function(d){ if(!d)return;if(d.Error){showErr(d.Error);return;}sparks();loadDrainStatus();loadProcessStatus();}).catch(function(e){showErr(e.message);});}
    function serviceControl(a){var l={stop:'Stop Service',start:'Start Service',restart:'Restart Service'},m={stop:'Stop the xFACtsOrchestrator Windows service.'+(isDraining?' Drain mode will remain engaged.':' The engine is currently online.'),start:'Start the xFACtsOrchestrator Windows service.'+(isDraining?' Note: drain mode is still engaged. The engine will not launch processes until drain mode is disengaged.':' The engine will resume normal operations.'),restart:'Stop and restart the xFACtsOrchestrator Windows service.'+(isDraining?' Drain mode will remain engaged.':' The engine is currently online.')},t={stop:'danger',start:isDraining?'danger':'safe',restart:'danger'};showConfirm(l[a],m[a],l[a],t[a],function(){doServiceControl(a);});}
    function doServiceControl(a){['stop','start','restart'].forEach(function(x){var b=document.getElementById('svc-btn-'+x);if(b)b.disabled=true;});engineFetch('/api/admin/service-control',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({action:a})}).then(function(d){ if(!d)return;if(d.Error){showErr(d.Error);loadDrainStatus();return;}serviceStatus=d.service_status||'Unknown';renderDrain();renderEnginePip();loadDrainStatus();}).catch(function(e){showErr(e.message);loadDrainStatus();});}
    function sparks(){var c=document.getElementById('spark-container');if(!c)return;var pl=c.closest('.breaker-housing').querySelector('.breaker-plate'),cx=pl.offsetWidth/2,cy=pl.offsetHeight/2;for(var i=0;i<14;i++){var s=document.createElement('div');s.classList.add('spark');var a=(Math.PI*2*i)/14+(Math.random()-0.5)*0.6,d=20+Math.random()*25;s.style.cssText='left:'+cx+'px;top:'+cy+'px;width:'+(1+Math.random()*2)+'px;height:'+(1+Math.random()*2)+'px;background:'+(Math.random()>0.5?'#fbbf24':'#fff')+';--tx:'+(Math.cos(a)*d)+'px;--ty:'+(Math.sin(a)*d)+'px;animation:spark-fly '+(0.3+Math.random()*0.3)+'s ease-out forwards;';c.appendChild(s);(function(el){setTimeout(function(){el.remove();},600);})(s);}}
    function toggleProcess(pid,en,name){if(en)showConfirm('Disable Process','Disable '+name+'? It will not be launched on the next cycle.','Disable','danger',function(){doToggleProcess(pid,'disable');});else showConfirm('Enable Process','Enable '+name+'? It will resume on the next scheduled cycle.','Enable','safe',function(){doToggleProcess(pid,'enable');});}
    function doToggleProcess(pid,action){engineFetch('/api/admin/toggle-process',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({process_id:pid,action:action})}).then(function(d){ if(!d)return;if(d.Error){showErr(d.Error);return;}loadProcessStatus();}).catch(function(e){showErr(e.message);});}
    function showConfirm(t,m,btn,type,fn){document.getElementById('confirm-title').textContent=t;document.getElementById('confirm-message').textContent=m;var b=document.getElementById('confirm-btn');b.textContent=btn;b.className='confirm-btn action '+type;pendingConfirm=fn;document.getElementById('confirm-overlay').classList.add('visible');}
    function cancelConfirm(){document.getElementById('confirm-overlay').classList.remove('visible');pendingConfirm=null;}
    function executeConfirm(){document.getElementById('confirm-overlay').classList.remove('visible');if(pendingConfirm){pendingConfirm();pendingConfirm=null;}}

    // ================================================================
    // METADATA + GLOBALCONFIG OPENERS
    // ================================================================
    // ================================================================
    // SHARED: Module descriptions (loaded once, used by all panels)
    // ================================================================
    var adminModules={};
    function loadAdminModules(){
        if(Object.keys(adminModules).length>0)return Promise.resolve();
        return engineFetch('/api/admin/modules').then(function(data){
            if(!data||data.Error)return;
            (Array.isArray(data)?data:[]).forEach(function(m){adminModules[m.module_name]=m.description||'';});
        }).catch(function(){});
    }

    // ================================================================
    // METADATA + GLOBALCONFIG + SCHEDULER OPENERS
    // ================================================================
    function openMetadata(){metaReset();openMetaPanel();metaLoadTree();}
    function openGlobalConfig(){gcReset();gcShow();loadAdminModules().then(function(){gcGo();});}
    function openSchedules(){schedReset();schedShow();loadAdminModules().then(function(){schedLoad();});}

    // GLOBALCONFIG
    var gcAllSettings=[],gcExpandedMod=null,gcExpandedId=null,gcEditingId=null,gcAddingTo=null,gcShowInactive={};
    function gcShow(){document.getElementById('gc-backdrop').classList.add('visible');document.getElementById('gc-panel').classList.add('visible');}
    function closeGlobalConfig(){document.getElementById('gc-backdrop').classList.remove('visible');document.getElementById('gc-panel').classList.remove('visible');}
    function gcReset(){gcAllSettings=[];gcExpandedMod=null;gcExpandedId=null;gcEditingId=null;gcAddingTo=null;gcShowInactive={};document.getElementById('gc-status').textContent='';document.getElementById('gc-status').className='meta-status';document.getElementById('gc-tree-list').innerHTML='';document.getElementById('gc-results-count').textContent='';}
    function gcGo(){document.getElementById('gc-tree-list').innerHTML='<div class="loading" style="padding:20px;">Loading settings...</div>';engineFetch('/api/admin/globalconfig/settings').then(function(data){ if(!data)return;if(data.Error){gcShowStatus(data.Error,true);return;}gcAllSettings=Array.isArray(data)?data:[];renderGcTree();}).catch(function(e){gcShowStatus(e.message,true);});}
    function renderGcTree(){var c=document.getElementById('gc-tree-list');if(gcAllSettings.length===0){c.innerHTML='<div style="text-align:center;color:#555;padding:24px;">No UI-editable settings found</div>';return;}var modules={},inactiveModules={};gcAllSettings.forEach(function(s){var mod=s.module_name||'Other';if(s.is_active===false||s.is_active===0||s.is_active==='0'||s.is_active===null){if(!inactiveModules[mod])inactiveModules[mod]=[];inactiveModules[mod].push(s);}else{if(!modules[mod])modules[mod]=[];modules[mod].push(s);}});var activeCount=0,inactiveCount=0;gcAllSettings.forEach(function(s){if(s.is_active===false||s.is_active===0||s.is_active==='0'||s.is_active===null)inactiveCount++;else activeCount++;});document.getElementById('gc-results-count').textContent=activeCount+' setting'+(activeCount!==1?'s':'')+(inactiveCount>0?' ('+inactiveCount+' inactive)':'');var html='',allMods={};Object.keys(modules).forEach(function(m){allMods[m]=true;});Object.keys(inactiveModules).forEach(function(m){allMods[m]=true;});var modNames=Object.keys(allMods).sort();modNames.forEach(function(mod){var active=modules[mod]||[],inactive=inactiveModules[mod]||[],totalLabel=active.length+(inactive.length>0?' + '+inactive.length+' inactive':''),isExp=gcExpandedMod===mod,modDesc=adminModules[mod]||'';html+='<div class="gc-mod-row'+(isExp?' expanded':'')+'"><div class="gc-mod-header" onclick="Admin.gcToggleMod(\''+esc(mod)+'\')">'+'<span class="meta-parent-chevron">'+(isExp?'\u25BC':'\u25B6')+'</span><span class="gc-mod-name">'+esc(mod)+'</span>'+(modDesc?'<span class="meta-parent-desc">'+esc(modDesc)+'</span>':'')+'<span class="meta-parent-count">'+totalLabel+'</span><button class="meta-add-btn" onclick="event.stopPropagation();Admin.gcStartAdd(\''+esc(mod)+'\')" title="Add new setting">+</button></div></div>';if(isExp){if(gcAddingTo===mod)html+=renderGcAddForm(mod);var cats={},catOrd=[];active.forEach(function(s){var cat=s.category||'';if(!cats[cat]){cats[cat]=[];catOrd.push(cat);}cats[cat].push(s);});catOrd.forEach(function(cat){if(catOrd.length>1||cat)html+='<div class="gc-category-label">'+esc(cat||'General')+'</div>';cats[cat].forEach(function(s){html+=renderGcChildCard(s,false);});});if(inactive.length>0){var showInact=gcShowInactive[mod];html+='<div class="gc-inactive-toggle" onclick="Admin.gcToggleInactive(\''+esc(mod)+'\')">'+(showInact?'\u25BC':'\u25B6')+' '+inactive.length+' inactive setting'+(inactive.length!==1?'s':'')+'</div>';if(showInact){inactive.forEach(function(s){html+=renderGcChildCard(s,true);});}}}});c.innerHTML=html;}
    function renderGcChildCard(s,isInactive){var isExp=gcExpandedId===s.config_id;var toggleState=isInactive?'off':'on';var toggleHtml='<span class="gc-active-toggle" onclick="event.stopPropagation();Admin.gcToggleActive('+s.config_id+','+(isInactive?'1':'0')+')" title="'+(isInactive?'Reactivate':'Deactivate')+'"><span class="gc-toggle"><span class="gc-toggle-track '+toggleState+'"><span class="gc-toggle-knob"></span></span></span></span>';if(isInactive){return'<div class="gc-child-card inactive" data-cid="'+s.config_id+'"><div class="gc-child-header" onclick="Admin.gcToggleRow('+s.config_id+')"><span class="gc-child-desc">'+esc(s.description||s.setting_name)+'</span><span class="gc-child-name">'+esc(s.setting_name)+'</span><span class="gc-child-value"><span class="gc-val-inactive">'+esc(s.setting_value)+'</span></span>'+toggleHtml+'</div><div class="gc-child-body">'+(isExp?renderGcDetail(s):'')+'</div></div>';}return'<div class="gc-child-card'+(isExp?' expanded':'')+'" data-cid="'+s.config_id+'"><div class="gc-child-header" onclick="Admin.gcToggleRow('+s.config_id+')"><span class="gc-child-desc">'+esc(s.description||s.setting_name)+'</span><span class="gc-child-name">'+esc(s.setting_name)+'</span><span class="gc-child-value" onclick="event.stopPropagation()">'+renderGcValue(s)+'</span>'+toggleHtml+'</div><div class="gc-child-body">'+(isExp?renderGcDetail(s):'')+'</div></div>';}
    function renderGcValue(s){if(s.data_type==='ALERT_MODE'){var v=parseInt(s.setting_value)||0;var teamsOn=(v&1)===1,jiraOn=(v&2)===2;return'<span class="gc-alert-badges">'+'<span class="gc-alert-badge teams'+(teamsOn?' on':' off')+'" onclick="Admin.gcToggleAlertMode('+s.config_id+',\'teams\')" title="Teams alerts">Teams</span>'+'<span class="gc-alert-badge jira'+(jiraOn?' on':' off')+'" onclick="Admin.gcToggleAlertMode('+s.config_id+',\'jira\')" title="Jira tickets">Jira</span>'+'</span>';}if(s.data_type==='BIT'){var isOn=s.setting_value==='1';return'<span class="gc-val-bit" onclick="Admin.gcToggleBit('+s.config_id+')" title="Click to toggle"><span class="gc-toggle"><span class="gc-toggle-track '+(isOn?'on':'off')+'"><span class="gc-toggle-knob"></span></span><span class="gc-toggle-label">'+(isOn?'ON':'OFF')+'</span></span></span>';}if(gcEditingId===s.config_id)return'<span class="gc-edit-wrap"><input type="text" class="gc-edit-input" id="gc-edit-'+s.config_id+'" value="'+esc(s.setting_value)+'" onkeydown="if(event.key===\'Enter\')Admin.gcSaveEdit('+s.config_id+');if(event.key===\'Escape\')Admin.gcCancelEdit()"><button class="gc-edit-save" onclick="Admin.gcSaveEdit('+s.config_id+')" title="Save">&#10003;</button><button class="gc-edit-cancel" onclick="Admin.gcCancelEdit()" title="Cancel">&#10007;</button></span>';return'<span class="gc-val-text" onclick="Admin.gcStartEdit('+s.config_id+')" title="Click to edit">'+esc(s.setting_value)+'</span>';}
    function renderGcDetail(s){var html='<div class="gc-detail-grid"><div class="gc-detail-desc">'+esc(s.description||'No description')+'</div>';if(s.notes)html+='<div class="gc-detail-notes">'+esc(s.notes)+'</div>';if(s.category)html+='<div class="gc-detail-item"><span class="gc-detail-label">Category: </span><span class="gc-detail-value">'+esc(s.category)+'</span></div>';var isActive=!(s.is_active===false||s.is_active===0||s.is_active==='0'||s.is_active===null);if(isActive){html+='<div class="gc-detail-deactivate"><span class="gc-deactivate-link" onclick="Admin.gcToggleActive('+s.config_id+',0)">Deactivate this setting</span></div>';}html+='</div><div class="gc-history" id="gc-history-'+s.config_id+'"></div>';return html;}
    function gcLoadHistory(cid){var ct=document.getElementById('gc-history-'+cid);if(!ct)return;ct.innerHTML='<div class="gc-history-loading">Loading history...</div>';engineFetch('/api/admin/globalconfig/history?config_id='+cid).then(function(data){ if(!data)return;if(data.Error){ct.innerHTML='';return;}var arr=Array.isArray(data)?data:[];if(arr.length===0){ct.innerHTML='<div class="gc-history-empty">No change history</div>';return;}var html='<div class="gc-history-header">Change History ('+arr.length+')</div><div class="gc-history-list">';arr.forEach(function(h){html+='<div class="gc-history-entry"><span class="gc-history-ts">'+fmtTs(h.changed_dttm)+'</span><span class="gc-history-user">'+esc(h.changed_by)+'</span><span class="gc-history-change"><span class="gc-history-old">'+esc(h.old_value||'(null)')+'</span> &rarr; <span class="gc-history-new">'+esc(h.new_value)+'</span></span></div>';});html+='</div>';ct.innerHTML=html;}).catch(function(){ct.innerHTML='';});}
    function gcToggleMod(mod){gcExpandedId=null;gcEditingId=null;gcAddingTo=null;gcExpandedMod=gcExpandedMod===mod?null:mod;renderGcTree();}
    function gcToggleRow(cid){gcEditingId=null;gcAddingTo=null;gcExpandedId=gcExpandedId===cid?null:cid;renderGcTree();if(gcExpandedId){gcLoadHistory(cid);var el=document.querySelector('.gc-child-card[data-cid="'+cid+'"]');if(el)el.scrollIntoView({behavior:'smooth',block:'nearest'});}}
    function gcStartAdd(mod){gcExpandedId=null;gcEditingId=null;if(gcAddingTo===mod)gcAddingTo=null;else{gcAddingTo=mod;gcExpandedMod=mod;}renderGcTree();}
    function gcCancelAdd(){gcAddingTo=null;gcExpandedMod=null;renderGcTree();}
    function renderGcAddForm(mod){return'<div class="meta-add-form meta-add-child"><div class="meta-add-title">New Setting: '+esc(mod)+'<button class="gc-add-close" onclick="Admin.gcCancelAdd()" title="Cancel">&times;</button></div><div class="gc-add-hint">Names must be lowercase with underscores (e.g. my_setting_name)</div><div class="meta-add-row"><input type="text" class="meta-add-input" id="gc-new-name" placeholder="setting_name" maxlength="100" onkeydown="if(event.key===\'Enter\')Admin.gcSubmitAdd(\''+esc(mod)+'\')"><select class="meta-select gc-add-type" id="gc-new-type"><option value="INT">INT</option><option value="BIT">BIT</option><option value="DECIMAL">DECIMAL</option><option value="VARCHAR">VARCHAR</option></select></div><div class="meta-add-row"><input type="text" class="meta-add-input" id="gc-new-value" placeholder="Default value" maxlength="500" style="flex:0 0 140px;"><input type="text" class="meta-add-input" id="gc-new-category" placeholder="Category (optional)" maxlength="50" style="flex:0 0 140px;"></div><div class="meta-add-row"><input type="text" class="meta-desc-input" id="gc-new-desc" placeholder="Description (required)" maxlength="500" style="flex:1;"><button class="meta-insert-btn" onclick="Admin.gcSubmitAdd(\''+esc(mod)+'\')">Insert</button></div><div class="meta-bump-status" id="gc-new-status"></div></div>';}
    function gcSubmitAdd(mod){var name=(document.getElementById('gc-new-name').value||'').trim(),dt=document.getElementById('gc-new-type').value,val=(document.getElementById('gc-new-value').value||'').trim(),cat=(document.getElementById('gc-new-category').value||'').trim(),desc=(document.getElementById('gc-new-desc').value||'').trim(),st=document.getElementById('gc-new-status');if(!name){st.textContent='Setting name required';st.className='meta-bump-status error';return;}if(!/^[a-z][a-z0-9_]*$/.test(name)){st.textContent='Name must be lowercase letters, numbers, and underscores only';st.className='meta-bump-status error';return;}if(val===''){st.textContent='Default value required';st.className='meta-bump-status error';return;}if(!desc){st.textContent='Description required';st.className='meta-bump-status error';return;}showConfirm('Insert Setting','Create '+mod+'.'+name+' ('+dt+')?','Insert','safe',function(){engineFetch('/api/admin/globalconfig/insert',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({module_name:mod,setting_name:name,setting_value:val,data_type:dt,category:cat||null,description:desc})}).then(function(d){ if(!d)return;if(d.Error){st.textContent=d.Error;st.className='meta-bump-status error';return;}st.textContent='Created '+name;st.className='meta-bump-status success';gcAddingTo=null;setTimeout(function(){gcGo();},600);}).catch(function(e){st.textContent=e.message;st.className='meta-bump-status error';});});}
    function gcToggleBit(cid){var s=gcFindSetting(cid);if(!s)return;var nv=s.setting_value==='1'?'0':'1',lbl=s.module_name+'.'+s.setting_name,act=nv==='1'?'Enable':'Disable';showConfirm(act+' Setting',act+' '+lbl+'?',act,nv==='1'?'safe':'danger',function(){gcDoUpdate(cid,nv);});}
    function gcToggleAlertMode(cid,channel){var s=gcFindSetting(cid);if(!s)return;var v=parseInt(s.setting_value)||0;if(channel==='teams')v=v^1;else if(channel==='jira')v=v^2;var nv=String(v);var labels=[];if(v&1)labels.push('Teams');if(v&2)labels.push('Jira');var desc=labels.length>0?labels.join(' + '):'None';showConfirm('Update Alert Routing','Set '+s.setting_name+' to '+desc+'?','Update','safe',function(){gcDoUpdate(cid,nv);});}
    function gcStartEdit(cid){gcEditingId=cid;renderGcTree();var inp=document.getElementById('gc-edit-'+cid);if(inp){inp.focus();inp.select();}}
    function gcCancelEdit(){gcEditingId=null;renderGcTree();}
    function gcSaveEdit(cid){var inp=document.getElementById('gc-edit-'+cid);if(!inp)return;var nv=inp.value.trim(),s=gcFindSetting(cid);if(!s)return;if(nv===s.setting_value){gcCancelEdit();return;}if(!nv)return;showConfirm('Update Setting','Change '+s.module_name+'.'+s.setting_name+' from \''+s.setting_value+'\' to \''+nv+'\'?','Update','safe',function(){gcDoUpdate(cid,nv);});}
    function gcDoUpdate(cid,nv){engineFetch('/api/admin/globalconfig/update',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({config_id:cid,setting_value:nv})}).then(function(d){ if(!d)return;if(d.Error){gcShowStatus(d.Error,true);return;}var s=gcFindSetting(cid);if(s)s.setting_value=nv;gcEditingId=null;renderGcTree();gcShowStatus(d.message,false);}).catch(function(e){gcShowStatus(e.message,true);});}
    function gcFindSetting(cid){for(var i=0;i<gcAllSettings.length;i++){if(gcAllSettings[i].config_id===cid)return gcAllSettings[i];}return null;}
    function gcShowStatus(msg,isErr){var el=document.getElementById('gc-status');if(el){el.textContent=msg;el.className='meta-status '+(isErr?'error':'success');}if(!isErr)setTimeout(function(){if(el){el.textContent='';el.className='meta-status';}},3000);}
    function gcToggleActive(cid,newState){var s=gcFindSetting(cid);if(!s)return;var lbl=s.module_name+'.'+s.setting_name,act=newState===1?'Reactivate':'Deactivate';showConfirm(act+' Setting',act+' '+lbl+'?',act,newState===1?'safe':'danger',function(){engineFetch('/api/admin/globalconfig/update',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({config_id:cid,field_name:'is_active',new_value:String(newState)})}).then(function(d){ if(!d)return;if(d.Error){gcShowStatus(d.Error,true);return;}gcShowStatus(d.message,false);gcGo();}).catch(function(e){gcShowStatus(e.message,true);});});}
    function gcToggleInactive(mod){gcShowInactive[mod]=!gcShowInactive[mod];renderGcTree();}

    // ================================================================
    // SYSTEM METADATA (Rearchitected — Component-Level Versioning)
    // Data: Component_Registry → Object_Registry → System_Metadata
    // Tree: root → module → component

    // ================================================================
    // SYSTEM METADATA (Component-Level Versioning)
    // ================================================================
    var metaComponents=[],metaModules={},metaTotals=null,metaExpandedMod=null,metaExpandedComp=null,metaObjectCache={};

    function openMetadata(){metaReset();openMetaPanel();metaLoadTree();}
    function openMetaPanel(){document.getElementById('meta-backdrop').classList.add('visible');document.getElementById('meta-panel').classList.add('visible');}
    function closeMetadata(){closeDetail();document.getElementById('meta-backdrop').classList.remove('visible');document.getElementById('meta-panel').classList.remove('visible');}
    function metaReset(){metaComponents=[];metaModules={};metaTotals=null;metaExpandedMod=null;metaExpandedComp=null;metaObjectCache={};document.getElementById('meta-tree-list').innerHTML='';document.getElementById('meta-results-count').textContent='';var st=document.getElementById('meta-status');st.textContent='';st.className='meta-status';}

    function metaLoadTree(){
        document.getElementById('meta-tree-list').innerHTML='<div class="loading" style="padding:20px;">Loading metadata...</div>';
        engineFetch('/api/admin/metadata/tree').then(function(data){
            if(!data)return;
            if(data.Error){metaShowStatus(data.Error,true);return;}
            metaComponents=Array.isArray(data.components)?data.components:[];
            metaTotals=data.totals||null;
            metaModules={};
            (Array.isArray(data.modules)?data.modules:[]).forEach(function(m){metaModules[m.module_name]=m.description||'';});
            var objCount=metaTotals?metaTotals.object_count:0;
            document.getElementById('meta-results-count').textContent=objCount+' object'+(objCount!==1?'s':'')+' across '+metaComponents.length+' component'+(metaComponents.length!==1?'s':'');
            renderMetaTree();
        }).catch(function(e){metaShowStatus(e.message,true);});
    }

    function renderMetaTree(){
        var c=document.getElementById('meta-tree-list');
        if(metaComponents.length===0){c.innerHTML='<div style="text-align:center;color:#555;padding:24px;">No components found</div>';return;}
        var modules={},modOrder=[];
        metaComponents.forEach(function(comp){
            var mod=comp.module_name;
            if(!modules[mod]){modules[mod]=[];modOrder.push(mod);}
            modules[mod].push(comp);
        });
        var html='';
        html+=renderMetaRootRow();
        modOrder.forEach(function(mod){
            var comps=modules[mod];
            var isExp=metaExpandedMod===mod;
            var modObjCount=0;
            comps.forEach(function(comp){modObjCount+=(comp.object_count||0);});
            html+='<div class="meta-parent-row'+(isExp?' expanded':'')+'">';
            html+='<div class="meta-parent-header" onclick="Admin.metaToggleMod(\''+esc(mod)+'\')">';
            html+='<span class="meta-parent-chevron">'+(isExp?'\u25BC':'\u25B6')+'</span>';
            html+='<span class="meta-parent-name">'+esc(mod)+'</span>';
            var modDesc=metaModules[mod]||'';
            if(modDesc) html+='<span class="meta-parent-desc">'+esc(modDesc)+'</span>';
            html+='<span class="meta-parent-count">'+comps.length+' component'+(comps.length!==1?'s':'')+' \u00B7 '+modObjCount+' object'+(modObjCount!==1?'s':'')+'</span>';
            html+='</div></div>';
            if(isExp){comps.forEach(function(comp){html+=renderMetaCompRow(comp);});}
        });
        c.innerHTML=html;
    }

    function renderMetaRootRow(){
        var isExp=metaExpandedMod==='__root__';
        var compCount=metaTotals?metaTotals.component_count:metaComponents.length;
        var objCount=metaTotals?metaTotals.object_count:0;
        var lastActivity=metaTotals?metaTotals.last_activity:null;
        return'<div class="meta-root-row'+(isExp?' expanded':'')+'">'
            +'<div class="meta-root-header" onclick="Admin.metaToggleRoot()">'
            +'<span class="meta-root-chevron">'+(isExp?'\u25BC':'\u25B6')+'</span>'
            +'<span class="meta-root-icon">&#128450;</span>'
            +'<span class="meta-root-name">xFACts</span>'
            +'<span class="meta-parent-count">'+compCount+' component'+(compCount!==1?'s':'')+' \u00B7 '+objCount+' object'+(objCount!==1?'s':'')+'</span>'
            +'</div>'
            +'<div class="meta-root-body">'+(isExp?renderMetaRootDetail(lastActivity):'')+'</div>'
            +'</div>';
    }

    function renderMetaRootDetail(lastActivity){
        var html='<div class="meta-root-info">';
        if(lastActivity) html+='<div class="meta-root-stat">Last activity: '+fmtDateShort(lastActivity)+'</div>';
        html+='</div>';
        return html;
    }

    function renderMetaCompRow(comp){
        var isExp=metaExpandedComp===comp.component_name;
        var shortName=comp.component_name;
        var html='<div class="meta-child-card'+(isExp?' expanded':'')+'" data-comp="'+esc(comp.component_name)+'"'+(isExp?'':' onclick="Admin.metaToggleComp(\''+esc(comp.component_name)+'\')"')+'>';
        html+='<div class="meta-child-header"'+(isExp?' onclick="Admin.metaToggleComp(\''+esc(comp.component_name)+'\')"':'')+'>';
        html+='<span class="meta-child-name" title="'+esc(comp.component_name)+'">'+esc(shortName)+'</span>';
        html+='<span class="meta-child-dots"></span>';
        html+='<span class="meta-child-objcount" title="'+comp.object_count+' registered objects">'+comp.object_count+' obj</span>';
        html+='<span class="meta-child-ver">'+esc(comp.version||'-')+'</span>';
        html+='</div>';
        if(comp.component_description){html+='<div class="meta-child-desc">'+esc(comp.component_description)+'</div>';}
        html+='<div class="meta-child-body">';
        if(isExp) html+=renderMetaCompExpanded(comp);
        html+='</div></div>';
        return html;
    }

    function renderMetaCompExpanded(comp){
        var cn=comp.component_name;
        var p=(comp.version||'0.0.0').split('.'),b=[parseInt(p[0])||0,parseInt(p[1])||0,parseInt(p[2])||0];
        var v2=b[2]+1,v1=b[1],v0=b[0];
        if(v2>9){v2=0;v1++;}
        if(v1>9){v1=0;v0++;}
        var html='<div class="meta-bump-section">';
        html+='<div class="meta-bump-row">';
        html+='<span class="meta-bump-label">Version</span>';
        html+='<span class="ver-bump ver-next">'+v0+'</span>';
        html+='<span class="ver-dot">.</span>';
        html+='<span class="ver-bump ver-next">'+v1+'</span>';
        html+='<span class="ver-dot">.</span>';
        html+='<span class="ver-bump ver-next">'+v2+'</span>';
        html+='<span class="meta-bump-spacer"></span>';
        html+='<button class="meta-cancel-btn" onclick="event.stopPropagation();Admin.metaToggleComp(\''+esc(cn)+'\')">Cancel</button>';
        html+='<button class="meta-insert-btn meta-insert-disabled" id="ins_'+esc(cn)+'" onclick="event.stopPropagation();Admin.metaInsert(\''+esc(cn)+'\')" disabled>Insert</button>';
        html+='</div>';
        html+='<div class="meta-bump-hint">Next version. Current: '+esc(comp.version||'-')+'</div>';
        html+='<div class="meta-desc-row">';
        html+='<textarea class="meta-desc-area" id="desc_'+esc(cn)+'" placeholder="Description of changes\u2026" maxlength="1000" rows="3" oninput="Admin.metaDescInput(\''+esc(cn)+'\')" onclick="event.stopPropagation()"></textarea>';
        html+='</div>';
        html+='<div class="meta-bump-status" id="bst_'+esc(cn)+'"></div>';
        html+='</div>';
        html+='<div class="meta-actions-row">';
        html+='<button class="meta-history-toggle" onclick="event.stopPropagation();Admin.metaLoadHistory(\''+esc(cn)+'\')">Version history</button>';
        html+='<button class="meta-history-toggle" onclick="event.stopPropagation();Admin.metaLoadObjects(\''+esc(cn)+'\')">Object catalog ('+comp.object_count+')</button>';
        html+='</div>';
        return html;
    }

    function metaToggleRoot(){metaExpandedComp=null;metaExpandedMod=metaExpandedMod==='__root__'?null:'__root__';renderMetaTree();}
    function metaToggleMod(mod){metaExpandedComp=null;metaExpandedMod=metaExpandedMod===mod?null:mod;renderMetaTree();if(metaExpandedMod&&metaExpandedMod!=='__root__'){var el=document.querySelector('.meta-parent-row.expanded');if(el)el.scrollIntoView({behavior:'smooth',block:'start'});}}
    function metaToggleComp(cn){metaExpandedComp=metaExpandedComp===cn?null:cn;renderMetaTree();if(metaExpandedComp){var el=document.querySelector('.meta-child-card[data-comp="'+cn+'"]');if(el)el.scrollIntoView({behavior:'smooth',block:'center'});}}

    function metaDescInput(cn){
        var desc=(document.getElementById('desc_'+cn).value||'').trim();
        var btn=document.getElementById('ins_'+cn);
        if(btn){
            if(desc.length>0){btn.disabled=false;btn.classList.remove('meta-insert-disabled');}
            else{btn.disabled=true;btn.classList.add('meta-insert-disabled');}
        }
    }

    function metaInsert(cn){
        var comp=metaFindComp(cn);if(!comp)return;
        var desc=(document.getElementById('desc_'+cn).value||'').trim();
        if(!desc){metaBumpStatus(cn,'Description required',true);return;}
        var p=(comp.version||'0.0.0').split('.'),b=[parseInt(p[0])||0,parseInt(p[1])||0,parseInt(p[2])||0];
        var v2=b[2]+1,v1=b[1],v0=b[0];
        if(v2>9){v2=0;v1++;}
        if(v1>9){v1=0;v0++;}
        var ver=v0+'.'+v1+'.'+v2;
        showConfirm('Insert Version','Insert '+cn+' v'+ver+'?','Insert','safe',function(){doMetaInsert(cn,ver,desc);});
    }

    function doMetaInsert(cn,ver,desc){
        var btn=document.getElementById('ins_'+cn);
        if(btn)btn.disabled=true;
        engineFetch('/api/admin/metadata/insert',{
            method:'POST',
            headers:{'Content-Type':'application/json'},
            body:JSON.stringify({component_name:cn,version:ver,description:desc})
        }).then(function(d){
            if(!d)return;
            if(d.Error){metaBumpStatus(cn,d.Error,true);if(btn)btn.disabled=false;return;}
            metaBumpStatus(cn,'Inserted '+cn+' v'+ver,false);
            setTimeout(function(){metaLoadTree();},800);
        }).catch(function(e){metaBumpStatus(cn,e.message,true);if(btn)btn.disabled=false;});
    }

    function metaBumpStatus(cn,msg,isErr){var el=document.getElementById('bst_'+cn);if(el){el.textContent=msg;el.className='meta-bump-status '+(isErr?'error':'success');}}

    var detailTypeBadge={
        'Table':      {cls:'cat-table',     label:'TABLE'},
        'Procedure':  {cls:'cat-proc',      label:'PROC'},
        'Trigger':    {cls:'cat-trigger',    label:'TRIGGER'},
        'DDL Trigger':{cls:'cat-ddltrigger', label:'DDL'},
        'View':       {cls:'cat-view',       label:'VIEW'},
        'Function':   {cls:'cat-function',   label:'FUNC'},
        'Script':     {cls:'cat-script',     label:'SCRIPT'},
        'XE Session': {cls:'cat-xe',         label:'XE'},
        'Route':      {cls:'cat-route',      label:'ROUTE'},
        'API':        {cls:'cat-api',        label:'API'},
        'JavaScript': {cls:'cat-js',         label:'JS'},
        'CSS':        {cls:'cat-css',        label:'CSS'},
        'HTML':       {cls:'cat-html',       label:'HTML'},
        'Module':     {cls:'cat-module',     label:'MODULE'}
    };

    function metaLoadHistory(cn){
        var panel=document.getElementById('detail-panel');
        if(panel.classList.contains('visible')&&panel._mode==='history'&&panel._comp===cn){closeDetail();return;}
        var shortName=cn;
        if(shortName.indexOf('.')>-1){var parts=shortName.split('.');shortName=parts[parts.length-1];}
        document.getElementById('detail-title').textContent=shortName+' \u2014 Version History';
        document.getElementById('detail-count').textContent='';
        document.getElementById('detail-body').innerHTML='<div style="color:#555;font-size:11px;padding:12px;">Loading\u2026</div>';
        panel._comp=cn;
        panel._mode='history';
        panel.classList.add('visible');

        engineFetch('/api/admin/metadata/history?component='+encodeURIComponent(cn)).then(function(data){
            if(!data)return;
            var panel2=document.getElementById('detail-panel');
            if(panel2._comp!==cn||panel2._mode!=='history')return;
            if(data.Error){document.getElementById('detail-body').innerHTML='<div style="color:#ef4444;font-size:11px;padding:12px;">'+esc(data.Error)+'</div>';return;}
            var arr=Array.isArray(data)?data:[];
            document.getElementById('detail-count').textContent=arr.length+' version'+(arr.length!==1?'s':'');
            if(arr.length===0){document.getElementById('detail-body').innerHTML='<div style="color:#555;font-size:11px;padding:12px;">No history found</div>';return;}
            var html='';
            arr.forEach(function(h){
                html+='<div class="detail-row">';
                html+='<span class="detail-row-type cat-table">'+esc(h.version)+'</span>';
                html+='<span class="detail-row-name" style="font-family:inherit;">'+esc(h.description||'-')+'</span>';
                html+='<span class="detail-row-path">'+fmtDateShort(h.deployed_date)+'</span>';
                html+='</div>';
            });
            document.getElementById('detail-body').innerHTML=html;
        }).catch(function(e){document.getElementById('detail-body').innerHTML='<div style="color:#ef4444;font-size:11px;padding:12px;">'+esc(e.message)+'</div>';});
    }

    function metaLoadObjects(cn){
        var panel=document.getElementById('detail-panel');
        if(panel.classList.contains('visible')&&panel._mode==='catalog'&&panel._comp===cn){closeDetail();return;}
        var shortName=cn;
        if(shortName.indexOf('.')>-1){var parts=shortName.split('.');shortName=parts[parts.length-1];}
        document.getElementById('detail-title').textContent=shortName+' \u2014 Object Catalog';
        document.getElementById('detail-count').textContent='';
        document.getElementById('detail-body').innerHTML='<div style="color:#555;font-size:11px;padding:12px;">Loading\u2026</div>';
        panel._comp=cn;
        panel._mode='catalog';
        panel.classList.add('visible');
        if(metaObjectCache[cn]){renderCatalog(cn,metaObjectCache[cn]);return;}
        engineFetch('/api/admin/metadata/objects?component='+encodeURIComponent(cn)).then(function(data){
            if(!data)return;
            var panel2=document.getElementById('detail-panel');
            if(panel2._comp!==cn||panel2._mode!=='catalog')return;
            if(data.Error){document.getElementById('detail-body').innerHTML='<div style="color:#ef4444;font-size:11px;padding:12px;">'+esc(data.Error)+'</div>';return;}
            var arr=Array.isArray(data)?data:[];
            metaObjectCache[cn]=arr;
            renderCatalog(cn,arr);
        }).catch(function(e){document.getElementById('detail-body').innerHTML='<div style="color:#ef4444;font-size:11px;padding:12px;">'+esc(e.message)+'</div>';});
    }

    function renderCatalog(cn,objects){
        var panel=document.getElementById('detail-panel');
        if(panel._comp!==cn||panel._mode!=='catalog')return;
        document.getElementById('detail-count').textContent=objects.length+' object'+(objects.length!==1?'s':'');
        if(objects.length===0){document.getElementById('detail-body').innerHTML='<div style="color:#555;font-size:11px;padding:12px;">No objects registered</div>';return;}
        var groups={},groupOrder=[];
        objects.forEach(function(o){
            var cat=o.object_category||'Other';
            if(!groups[cat]){groups[cat]=[];groupOrder.push(cat);}
            groups[cat].push(o);
        });
        var html='';
        groupOrder.forEach(function(cat){
            html+='<div class="detail-group-label">'+esc(cat)+' ('+groups[cat].length+')</div>';
            groups[cat].forEach(function(o){
                var badge=detailTypeBadge[o.object_type]||{cls:'',label:o.object_type};
                html+='<div class="detail-row">';
                html+='<span class="detail-row-type '+badge.cls+'">'+badge.label+'</span>';
                html+='<span class="detail-row-name">'+esc(o.object_name)+'</span>';
                if(o.object_path) html+='<span class="detail-row-path">'+esc(o.object_path)+'</span>';
                html+='</div>';
            });
        });
        document.getElementById('detail-body').innerHTML=html;
    }

    function closeDetail(){
        var panel=document.getElementById('detail-panel');
        panel.classList.remove('visible');
        panel._comp=null;
        panel._mode=null;
    }

    function metaFindComp(cn){for(var i=0;i<metaComponents.length;i++){if(metaComponents[i].component_name===cn)return metaComponents[i];}return null;}
    function metaShowStatus(msg,isErr){var el=document.getElementById('meta-status');if(el){el.textContent=msg;el.className='meta-status '+(isErr?'error':'success');}}

    // ================================================================
    // SCHEDULE EDITOR
    // ================================================================
    var schedAllProcesses=[],schedExpandedMod=null,schedExpandedId=null;
    var schedEditingField=null,schedAddingTo=null,schedAvailableScripts=[];

    function closeSchedules(){document.getElementById('sched-backdrop').classList.remove('visible');document.getElementById('sched-panel').classList.remove('visible');}
    function schedShow(){document.getElementById('sched-backdrop').classList.add('visible');document.getElementById('sched-panel').classList.add('visible');}
    function schedReset(){schedAllProcesses=[];schedExpandedMod=null;schedExpandedId=null;schedEditingField=null;schedAddingTo=null;schedAvailableScripts=[];document.getElementById('sched-status').textContent='';document.getElementById('sched-status').className='meta-status';document.getElementById('sched-tree-list').innerHTML='';document.getElementById('sched-results-count').textContent='';}

    function schedLoad(){
        document.getElementById('sched-tree-list').innerHTML='<div class="loading" style="padding:20px;">Loading processes...</div>';
        engineFetch('/api/admin/schedule/processes').then(function(data){ if(!data)return;
            if(data.Error){schedShowStatus(data.Error,true);return;}
            schedAllProcesses=Array.isArray(data)?data:[];
            document.getElementById('sched-results-count').textContent=schedAllProcesses.length+' process'+(schedAllProcesses.length!==1?'es':'');
            renderSchedTree();
        }).catch(function(e){schedShowStatus(e.message,true);});
    }

    function renderSchedTree(){
        var c=document.getElementById('sched-tree-list');
        if(schedAllProcesses.length===0){c.innerHTML='<div style="text-align:center;color:#555;padding:24px;">No processes found</div>';return;}
        var modules={};
        schedAllProcesses.forEach(function(p){var mod=p.module_name||'Other';if(!modules[mod])modules[mod]=[];modules[mod].push(p);});
        var html='',modNames=Object.keys(modules).sort();
        modNames.forEach(function(mod){
            var procs=modules[mod],isExp=schedExpandedMod===mod,modDesc=adminModules[mod]||'';
            html+='<div class="sched-mod-row'+(isExp?' expanded':'')+'">';
            html+='<div class="sched-mod-header" onclick="Admin.schedToggleMod(\''+esc(mod)+'\')">';
            html+='<span class="meta-parent-chevron">'+(isExp?'\u25BC':'\u25B6')+'</span>';
            html+='<span class="sched-mod-name">'+esc(mod)+'</span>';
            if(modDesc) html+='<span class="meta-parent-desc">'+esc(modDesc)+'</span>';
            html+='<span class="meta-parent-count">'+procs.length+'</span>';
            html+='<button class="meta-add-btn" onclick="event.stopPropagation();Admin.schedStartAdd(\''+esc(mod)+'\')" title="Add new process">+</button>';
            html+='</div></div>';
            if(isExp){
                if(schedAddingTo===mod)html+=renderSchedAddForm(mod);
                procs.forEach(function(p){html+=renderSchedCard(p);});
            }
        });
        c.innerHTML=html;
    }

    function renderSchedCard(p){
        var isExp=schedExpandedId===p.process_id;
        var modeLabel=p.execution_mode==='FIRE_AND_FORGET'?'F&F':'WAIT';
        var modeBadge='<span class="sched-mode-badge '+(p.execution_mode==='WAIT'?'wait':'ff')+'">'+modeLabel+'</span>';
        var statusCls=p.run_mode===0?'disabled':'enabled';
        var statusLabel=p.run_mode===0?'OFF':(p.run_mode===2?'QUEUE':'ON');
        var statusBadge='<span class="sched-status-badge '+statusCls+'">'+statusLabel+'</span>';
        var html='<div class="sched-child-card'+(isExp?' expanded':'')+'" data-pid="'+p.process_id+'">';
        html+='<div class="sched-child-header" onclick="Admin.schedToggleRow('+p.process_id+')">';
        html+=statusBadge;
        html+='<span class="sched-child-name">'+esc(p.process_name)+'</span>';
        html+='<span class="meta-child-dots"></span>';
        html+=modeBadge;
        html+='<span class="sched-child-group">G'+p.dependency_group+'</span>';
        html+='</div>';
        html+='<div class="sched-child-body">'+(isExp?renderSchedDetail(p):'')+'</div>';
        html+='</div>';
        return html;
    }

    function formatSchedTime(val){
        if(!val)return null;
        if(typeof val==='string'&&val.indexOf('/Date(')===0){var ms=parseInt(val.replace(/\/Date\((-?\d+)\)\//,'$1'));if(!isNaN(ms)){var td=new Date(ms);return(td.getHours()<10?'0':'')+td.getHours()+':'+(td.getMinutes()<10?'0':'')+td.getMinutes()+':'+(td.getSeconds()<10?'0':'')+td.getSeconds();}}
        if(typeof val==='string')return val;
        if(typeof val==='object'&&val!==null){
            var h=val.Hours||val.hours||0,m=val.Minutes||val.minutes||0,s=val.Seconds||val.seconds||0;
            if(typeof h==='number')return(h<10?'0':'')+h+':'+(m<10?'0':'')+m+':'+(s<10?'0':'')+s;
            if(val.TotalMilliseconds!==undefined){var tot=Math.floor(val.TotalMilliseconds/1000);h=Math.floor(tot/3600);m=Math.floor((tot%3600)/60);s=tot%60;return(h<10?'0':'')+h+':'+(m<10?'0':'')+m+':'+(s<10?'0':'')+s;}
        }
        return String(val);
    }

    function renderSchedDetail(p){
        var html='<div class="sched-detail">';
        html+='<div class="sched-info-card">';
        html+='<div class="sched-desc">'+esc(p.description||'No description')+'</div>';
        html+='<div class="sched-script"><span class="sched-script-label">Script</span><span class="sched-script-path">'+esc(p.script_path||'-')+'</span></div>';
        html+='</div>';
        html+='<div class="sched-settings-card">';
        html+='<div class="sched-settings-title">Configuration</div>';
        html+='<div class="sched-settings-grid">';
        var isFF=p.execution_mode==='FIRE_AND_FORGET';
        html+='<div class="sched-setting-item sched-setting-wide">';
        html+='<span class="sched-setting-label">Execution Mode</span>';
        html+='<span class="sched-setting-control">';
        html+='<span class="sched-toggle-wrap" onclick="Admin.schedToggleMode('+p.process_id+')" title="WAIT: Engine waits for process to finish before continuing.&#10;FIRE_AND_FORGET: Engine launches and moves on.">';
        html+='<span class="gc-toggle-track '+(isFF?'on':'off')+'"><span class="gc-toggle-knob"></span></span>';
        html+='<span class="gc-toggle-label">'+(isFF?'Fire & Forget':'Wait for Exit')+'</span></span></span></div>';
        html+=schedEditableField(p,'dependency_group','Dep. Group',p.dependency_group);
        html+=schedEditableField(p,'interval_seconds','Interval (sec)',p.interval_seconds);
        var schedTime=formatSchedTime(p.scheduled_time);
        html+=schedEditableField(p,'scheduled_time','Sched. Time',schedTime||'(none)');
        html+=schedEditableField(p,'timeout_seconds','Timeout (sec)',p.timeout_seconds!==null&&p.timeout_seconds!==undefined?p.timeout_seconds:'(none)');
        var isCon=p.allow_concurrent===true||p.allow_concurrent===1;
        html+='<div class="sched-setting-item sched-setting-wide">';
        html+='<span class="sched-setting-label">Allow Concurrent</span>';
        html+='<span class="sched-setting-control">';
        html+='<span class="sched-toggle-wrap" onclick="Admin.schedToggleConcurrent('+p.process_id+')">';
        html+='<span class="gc-toggle-track '+(isCon?'on':'off')+'"><span class="gc-toggle-knob"></span></span>';
        html+='<span class="gc-toggle-label">'+(isCon?'Yes':'No')+'</span></span></span></div>';
        html+='</div>';
        html+='</div>';
        html+='<div class="sched-card-status" id="sched-card-status-'+p.process_id+'"></div>';
        html+='</div>';
        return html;
    }

    function schedEditableField(p,field,label,displayVal){
        var isEditing=schedEditingField&&schedEditingField.pid===p.process_id&&schedEditingField.field===field;
        var html='<div class="sched-setting-item">';
        html+='<span class="sched-setting-label">'+label+'</span>';
        if(isEditing){
            html+='<span class="sched-setting-control"><span class="gc-edit-wrap">';
            html+='<input type="text" class="gc-edit-input sched-edit-input" id="sched-edit-input" value="'+esc(displayVal==='(none)'?'':displayVal)+'" onkeydown="if(event.key===\'Enter\')Admin.schedSaveField('+p.process_id+',\''+field+'\');if(event.key===\'Escape\')Admin.schedCancelEdit()">';
            html+='<button class="gc-edit-save" onclick="Admin.schedSaveField('+p.process_id+',\''+field+'\')" title="Save">&#10003;</button>';
            html+='<button class="gc-edit-cancel" onclick="Admin.schedCancelEdit()" title="Cancel">&#10007;</button>';
            html+='</span></span>';
        }else{
            html+='<span class="sched-setting-control"><span class="sched-setting-value" onclick="Admin.schedStartEdit('+p.process_id+',\''+field+'\')">'+esc(String(displayVal))+'</span></span>';
        }
        html+='</div>';
        return html;
    }

    function schedToggleMod(mod){schedExpandedId=null;schedEditingField=null;schedAddingTo=null;schedExpandedMod=schedExpandedMod===mod?null:mod;renderSchedTree();}
    function schedToggleRow(pid){schedEditingField=null;schedAddingTo=null;schedExpandedId=schedExpandedId===pid?null:pid;renderSchedTree();if(schedExpandedId){var el=document.querySelector('.sched-child-card[data-pid="'+pid+'"]');if(el)el.scrollIntoView({behavior:'smooth',block:'nearest'});}}

    function schedStartEdit(pid,field){schedEditingField={pid:pid,field:field};renderSchedTree();var inp=document.getElementById('sched-edit-input');if(inp){inp.focus();inp.select();}}
    function schedCancelEdit(){schedEditingField=null;renderSchedTree();}

    function schedSaveField(pid,field){
        var inp=document.getElementById('sched-edit-input');if(!inp)return;
        var newVal=inp.value.trim(),p=schedFindProcess(pid);if(!p)return;
        var currentVal=String(p[field]!==null&&p[field]!==undefined?p[field]:'');
        if(field==='scheduled_time'){currentVal=formatSchedTime(p[field])||'';}
        if(newVal===currentVal){schedCancelEdit();return;}
        var displayField=field.replace(/_/g,' ');
        showConfirm('Update '+displayField,'Change '+p.process_name+'.'+displayField+' from \''+currentVal+'\' to \''+newVal+'\'?','Update','safe',function(){schedDoUpdate(pid,field,currentVal,newVal);});
    }

    function schedToggleMode(pid){
        var p=schedFindProcess(pid);if(!p)return;
        var oldMode=p.execution_mode,newMode=oldMode==='FIRE_AND_FORGET'?'WAIT':'FIRE_AND_FORGET';
        var newLabel=newMode==='FIRE_AND_FORGET'?'Fire & Forget':'Wait for Exit';
        showConfirm('Change Execution Mode','Change '+p.process_name+' to '+newLabel+'?\n\nWAIT: The orchestrator waits for the process to finish before continuing.\nFIRE & FORGET: The orchestrator launches the process and moves on immediately.\n\nTakes effect on the next execution cycle.','Change','danger',function(){schedDoUpdate(pid,'execution_mode',oldMode,newMode);});
    }

    function schedToggleConcurrent(pid){
        var p=schedFindProcess(pid);if(!p)return;
        var oldVal=(p.allow_concurrent===true||p.allow_concurrent===1)?'1':'0';
        var newVal=oldVal==='1'?'0':'1',label=newVal==='1'?'Enable':'Disable';
        showConfirm(label+' Concurrent Execution',label+' concurrent execution for '+p.process_name+'?',label,newVal==='1'?'safe':'danger',function(){schedDoUpdate(pid,'allow_concurrent',oldVal,newVal);});
    }

    function schedDoUpdate(pid,field,oldVal,newVal){
        engineFetch('/api/admin/schedule/update',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({process_id:pid,field_name:field,old_value:oldVal,new_value:newVal})}).then(function(d){ if(!d)return;
            if(d.Error){schedShowCardStatus(pid,d.Error,true);return;}
            var p=schedFindProcess(pid);
            if(p){if(field==='allow_concurrent')p[field]=newVal==='1'?1:0;else if(field==='dependency_group'||field==='interval_seconds'||field==='timeout_seconds')p[field]=parseInt(newVal);else p[field]=newVal===''||newVal==='null'?null:newVal;}
            schedEditingField=null;renderSchedTree();schedShowCardStatus(pid,d.message,false);loadProcessStatus();
        }).catch(function(e){schedShowCardStatus(pid,e.message,true);});
    }

    function schedStartAdd(mod){
        schedExpandedId=null;schedEditingField=null;
        if(schedAddingTo===mod){schedAddingTo=null;}
        else{schedAddingTo=mod;schedExpandedMod=mod;schedLoadAvailableScripts();}
        renderSchedTree();
    }
    function schedCancelAdd(){schedAddingTo=null;renderSchedTree();}

    function schedLoadAvailableScripts(){
        engineFetch('/api/admin/schedule/browse-scripts').then(function(data){ if(!data)return;
            if(data.Error){schedShowStatus(data.Error,true);return;}
            schedAvailableScripts=Array.isArray(data)?data:[];renderSchedTree();
        }).catch(function(e){schedShowStatus(e.message,true);});
    }

    function renderSchedAddForm(mod){
        var html='<div class="meta-add-form meta-add-child">';
        html+='<div class="meta-add-title">New Process: '+esc(mod)+'<button class="gc-add-close" onclick="Admin.schedCancelAdd()" title="Cancel">&times;</button></div>';
        html+='<div class="meta-add-row"><label class="sched-add-label">Script</label>';
        html+='<select class="meta-select" id="sched-new-script" onchange="Admin.schedScriptSelected()">';
        html+='<option value="">Select a script...</option>';
        schedAvailableScripts.forEach(function(f){html+='<option value="'+esc(f)+'">'+esc(f)+'</option>';});
        if(schedAvailableScripts.length===0)html+='<option value="" disabled>Loading scripts...</option>';
        html+='</select></div>';
        html+='<div class="meta-add-row"><label class="sched-add-label">Process Name</label>';
        html+='<input type="text" class="meta-add-input" id="sched-new-name" placeholder="(auto-populated from script)" readonly></div>';
        html+='<div class="meta-add-row"><label class="sched-add-label">Description</label>';
        html+='<input type="text" class="meta-desc-input" id="sched-new-desc" placeholder="Description (required)" maxlength="500" style="flex:1;"></div>';
        html+='<div class="meta-add-row"><label class="sched-add-label">Execution Mode</label>';
        html+='<span class="sched-toggle-wrap" onclick="Admin.schedAddToggleMode()">';
        html+='<span class="gc-toggle-track on" id="sched-new-mode-track"><span class="gc-toggle-knob"></span></span>';
        html+='<span class="gc-toggle-label" id="sched-new-mode-label">Fire & Forget</span></span>';
        html+='<input type="hidden" id="sched-new-mode" value="FIRE_AND_FORGET"></div>';
        html+='<div class="sched-add-grid">';
        html+='<div class="sched-add-cell"><label class="sched-add-cell-label">Dependency Group</label><input type="number" class="sched-add-cell-input" id="sched-new-group" placeholder="Group #" min="1"></div>';
        html+='<div class="sched-add-cell"><label class="sched-add-cell-label">Interval (seconds)</label><input type="number" class="sched-add-cell-input" id="sched-new-interval" placeholder="Seconds" min="0" value="300"></div>';
        html+='<div class="sched-add-cell"><label class="sched-add-cell-label">Timeout (seconds)</label><input type="number" class="sched-add-cell-input" id="sched-new-timeout" placeholder="Seconds" min="1"></div>';
        html+='<div class="sched-add-cell"><label class="sched-add-cell-label">Scheduled Time</label><input type="text" class="sched-add-cell-input" id="sched-new-schedtime" placeholder="HH:mm:ss (optional)"></div>';
        html+='</div>';
        html+='<div class="meta-add-row" style="justify-content:flex-end;"><button class="meta-insert-btn" onclick="Admin.schedSubmitAdd(\''+esc(mod)+'\')">Add Process</button></div>';
        html+='<div class="meta-bump-status" id="sched-new-status"></div>';
        html+='</div>';
        return html;
    }

    function schedAddToggleMode(){
        var track=document.getElementById('sched-new-mode-track'),label=document.getElementById('sched-new-mode-label'),hidden=document.getElementById('sched-new-mode');
        if(!track||!hidden)return;
        if(hidden.value==='FIRE_AND_FORGET'){hidden.value='WAIT';track.className='gc-toggle-track off';label.textContent='Wait for Exit';}
        else{hidden.value='FIRE_AND_FORGET';track.className='gc-toggle-track on';label.textContent='Fire & Forget';}
    }

    function schedScriptSelected(){
        var sel=document.getElementById('sched-new-script'),nameEl=document.getElementById('sched-new-name'),descEl=document.getElementById('sched-new-desc');
        if(!sel||!nameEl)return;var file=sel.value;if(!file){nameEl.value='';return;}
        var procName=file.replace(/\.ps1$/i,'');nameEl.value=procName;
        if(!descEl.value){var desc=procName.replace(/-/g,' ').replace(/([a-z])([A-Z])/g,'$1 $2').replace(/^./,function(c){return c.toUpperCase();});descEl.value=desc;}
    }

    function schedSubmitAdd(mod){
        var script=(document.getElementById('sched-new-script').value||'').trim();
        var name=(document.getElementById('sched-new-name').value||'').trim();
        var desc=(document.getElementById('sched-new-desc').value||'').trim();
        var mode=document.getElementById('sched-new-mode').value;
        var group=(document.getElementById('sched-new-group').value||'').trim();
        var interval=(document.getElementById('sched-new-interval').value||'').trim();
        var timeout=(document.getElementById('sched-new-timeout').value||'').trim();
        var schedTime=(document.getElementById('sched-new-schedtime').value||'').trim();
        var st=document.getElementById('sched-new-status');
        if(!script){st.textContent='Select a script';st.className='meta-bump-status error';return;}
        if(!desc){st.textContent='Description is required';st.className='meta-bump-status error';return;}
        if(!group){st.textContent='Dependency group is required';st.className='meta-bump-status error';return;}
        if(!timeout){st.textContent='Timeout is required';st.className='meta-bump-status error';return;}
        showConfirm('Add Process','Register '+name+' in '+mod+'?\n\nThe process will be created DISABLED (run_mode = 0). Enable it manually when ready.','Add','safe',function(){
            engineFetch('/api/admin/schedule/add',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({module_name:mod,script_path:script,process_name:name,description:desc,execution_mode:mode,dependency_group:parseInt(group),interval_seconds:interval?parseInt(interval):300,scheduled_time:schedTime||null,timeout_seconds:parseInt(timeout)})}).then(function(d){ if(!d)return;
                if(d.Error){st.textContent=d.Error;st.className='meta-bump-status error';return;}
                st.textContent='Added '+name+' (disabled)';st.className='meta-bump-status success';
                schedAddingTo=null;setTimeout(function(){schedLoad();loadProcessStatus();},600);
            }).catch(function(e){st.textContent=e.message;st.className='meta-bump-status error';});
        });
    }

    function schedFindProcess(pid){for(var i=0;i<schedAllProcesses.length;i++){if(schedAllProcesses[i].process_id===pid)return schedAllProcesses[i];}return null;}
    function schedShowStatus(msg,isErr){var el=document.getElementById('sched-status');if(el){el.textContent=msg;el.className='meta-status '+(isErr?'error':'success');}if(!isErr)setTimeout(function(){if(el){el.textContent='';el.className='meta-status';}},3000);}
    function schedShowCardStatus(pid,msg,isErr){var el=document.getElementById('sched-card-status-'+pid);if(el){el.textContent=msg;el.className='sched-card-status '+(isErr?'error':'success');}if(!isErr)setTimeout(function(){if(el){el.textContent='';el.className='sched-card-status';}},3000);}

    // INPUT MODAL
    var inputModalCallback=null;
    function showInputModal(title,hint,dv,cb){inputModalCallback=cb;document.getElementById('input-modal-title').textContent=title;document.getElementById('input-modal-hint').textContent=hint;var f=document.getElementById('input-modal-field');f.value=dv||'';document.getElementById('input-modal-overlay').classList.add('visible');document.getElementById('input-modal').classList.add('visible');setTimeout(function(){f.focus();},100);}
    function cancelInput(){document.getElementById('input-modal-overlay').classList.remove('visible');document.getElementById('input-modal').classList.remove('visible');inputModalCallback=null;}
    function confirmInput(){var v=document.getElementById('input-modal-field').value,cb=inputModalCallback;cancelInput();if(cb&&v&&v.trim())cb(v.trim());}

    // UTIL
    function parseDate(v){if(!v)return null;if(typeof v==='string'&&v.indexOf('/Date(')===0){var ms=parseInt(v.replace(/\/Date\((-?\d+)\)\//,'$1'));return isNaN(ms)?null:new Date(ms);}var d=new Date(v);if(isNaN(d.getTime()))d=new Date(String(v).replace(' ','T'));return isNaN(d.getTime())?null:d;}
    function fmtTs(v){var d=parseDate(v);if(!d)return'-';return(d.getMonth()+1)+'/'+d.getDate()+' '+fmtT12(d);}
    function fmtT12(d){var h=d.getHours(),ap=h>=12?'p':'a';h=h%12||12;var m=d.getMinutes(),s=d.getSeconds();return h+':'+(m<10?'0':'')+m+':'+(s<10?'0':'')+s+ap;}
    function fmtDur(ms){if(ms===null||ms===undefined)return'-';if(ms<1000)return ms+'ms';if(ms<60000)return(ms/1000).toFixed(1)+'s';return Math.floor(ms/60000)+'m '+Math.floor((ms%60000)/1000)+'s';}
    function fmtDateShort(v){if(!v)return'-';var d=parseDate(v);if(!d)return'-';return(d.getMonth()+1)+'/'+d.getDate()+'/'+String(d.getFullYear()).slice(2);}
    function updateTs(){var el=document.getElementById('last-update');if(!el)return;el.textContent=fmtT12(new Date()).toUpperCase();}
    function showErr(m){var e=document.getElementById('connection-error');e.textContent=m;e.classList.add('visible');}
    function clearErr(){var e=document.getElementById('connection-error');e.textContent='';e.classList.remove('visible');}
    function esc(s){if(!s)return'';return String(s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;');}

    document.addEventListener('DOMContentLoaded',init);

    // ========================================================================
    // DOCUMENTATION PIPELINE
    // ========================================================================

    var docRunning = false;
    var docPollTimer = null;
    var docSelectedSteps = [];

    // Step-to-options mapping: which sub-option div belongs to which step toggle
    var docStepOptionMap = [
        { step: 'doc-step-publish',      card: 'doc-card-publish',      options: 'doc-step-publish-options' },
        { step: 'doc-step-consolidate',  card: 'doc-card-consolidate',  options: 'doc-step-consolidate-options' }
    ];

    // All step toggles (for card dimming)
    var docAllSteps = [
        { step: 'doc-step-ddl',          card: 'doc-card-ddl' },
        { step: 'doc-step-publish',      card: 'doc-card-publish' },
        { step: 'doc-step-github',       card: 'doc-card-github' },
        { step: 'doc-step-consolidate',  card: 'doc-card-consolidate' }
    ];

    function initDocStepToggles() {
        docAllSteps.forEach(function(s) {
            var cb = document.getElementById(s.step);
            if (cb) {
                cb.addEventListener('change', docUpdateCards);
            }
        });
        docUpdateCards();
    }

    function docUpdateCards() {
        // Update card dim state
        docAllSteps.forEach(function(s) {
            var cb = document.getElementById(s.step);
            var card = document.getElementById(s.card);
            if (cb && card) {
                if (cb.checked) { card.classList.remove('off'); }
                else { card.classList.add('off'); }
            }
        });
        // Update sub-option visibility
        docStepOptionMap.forEach(function(pair) {
            var cb = document.getElementById(pair.step);
            var opts = document.getElementById(pair.options);
            if (cb && opts) {
                opts.style.display = cb.checked ? '' : 'none';
            }
        });
    }

    function docTogglePill(el) {
        el.classList.toggle('active');
    }

    function openDocPipeline() {
        // Clear any previous results
        var res = document.getElementById('doc-results');
        if (res) res.innerHTML = '';
        var st = document.getElementById('doc-run-status');
        if (st) { st.textContent = ''; st.className = 'doc-run-status'; }
        var btn = document.getElementById('doc-run-btn');
        if (btn) { btn.disabled = false; btn.textContent = 'Run Selected'; btn.onclick = function() { runDocPipeline(); }; }

        document.getElementById('doc-backdrop').classList.add('visible');
        document.getElementById('doc-panel').classList.add('visible');

        docUpdateCards();
    }

    function closeDocPipeline() {
        if (docRunning) return;
        if (docPollTimer) { clearInterval(docPollTimer); docPollTimer = null; }
        document.getElementById('doc-backdrop').classList.remove('visible');
        document.getElementById('doc-panel').classList.remove('visible');
    }

    function runDocPipeline() {
        if (docRunning) return;

        // Collect selected steps
        var steps = [];
        if (document.getElementById('doc-step-ddl').checked) steps.push('generate_ddl');
        if (document.getElementById('doc-step-publish').checked) steps.push('publish_confluence');
        if (document.getElementById('doc-step-github').checked) steps.push('publish_github');
        if (document.getElementById('doc-step-consolidate').checked) steps.push('consolidate_upload');

        if (steps.length === 0) {
            var st = document.getElementById('doc-run-status');
            st.textContent = 'Select at least one step';
            st.className = 'doc-run-status error';
            return;
        }

        // Collect pill options
        var payload = {
            steps: steps,
            publish_to_confluence: document.getElementById('doc-opt-confluence').classList.contains('active'),
            export_markdown: document.getElementById('doc-opt-markdown').classList.contains('active'),
            include_sql_objects: document.getElementById('doc-opt-sql').classList.contains('active'),
            include_json: document.getElementById('doc-opt-json').classList.contains('active')
        };

        docRunning = true;
        docSelectedSteps = steps.slice();
        var btn = document.getElementById('doc-run-btn');
        btn.disabled = true;
        btn.textContent = 'Running...';

        var st = document.getElementById('doc-run-status');
        st.textContent = 'Launching pipeline...';
        st.className = 'doc-run-status running';

        var res = document.getElementById('doc-results');
        res.innerHTML = '';

        engineFetch('/api/admin/doc-pipeline', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(payload)
        })
        .then(function(data) {
            if (!data) return;
            if (data.Error) {
                docRunning = false;
                btn.disabled = false;
                btn.textContent = 'Run Selected';
                st.textContent = data.Error;
                st.className = 'doc-run-status error';
                return;
            }

            st.textContent = 'Pipeline running...';
            st.className = 'doc-run-status running';

            docPollTimer = setInterval(pollDocStatus, 2000);
            setTimeout(pollDocStatus, 500);
        })
        .catch(function(err) {
            docRunning = false;
            btn.disabled = false;
            btn.textContent = 'Run Selected';
            st.textContent = 'Launch failed: ' + err.message;
            st.className = 'doc-run-status error';
        });
    }

    function pollDocStatus() {
        engineFetch('/api/admin/doc-pipeline/status')
        .then(function(data) {
            if (!data) return;
            if (data.pending) return;

            var results = data.results || [];
            var st = document.getElementById('doc-run-status');

            // Update running count
            var doneCount = 0;
            results.forEach(function(r) { if (r.status !== 'running') doneCount++; });
            if (!data.complete) {
                st.textContent = 'Running... (' + doneCount + '/' + docSelectedSteps.length + ' complete)';
            }

            if (data.complete) {
                clearInterval(docPollTimer);
                docPollTimer = null;
                docRunning = false;

                var btn = document.getElementById('doc-run-btn');
                btn.disabled = false;
                btn.textContent = 'OK';
                btn.onclick = function() { closeDocPipeline(); };

                if (data.success) {
                    st.textContent = 'All steps completed successfully';
                    st.className = 'doc-run-status success';
                } else {
                    st.textContent = 'Pipeline completed with errors';
                    st.className = 'doc-run-status error';
                }

                // Build collapsible results
                var res = document.getElementById('doc-results');
                var html = '<div class="doc-results-divider">Results</div>';
                results.forEach(function(r) {
                    var ok = r.status === 'success';
                    var cls = ok ? 'ok' : 'fail';
                    var icon = ok ? '\u2713' : '\u2717';
                    var openAttr = ok ? '' : ' open';
                    html += '<details class="doc-detail ' + cls + '"' + openAttr + '>';
                    html += '<summary>';
                    html += '<span class="doc-detail-arrow">\u25B6</span>';
                    html += '<span class="doc-detail-icon">' + icon + '</span>';
                    html += '<span class="doc-detail-label">' + esc(r.label) + '</span>';
                    if (r.exit_code !== null && r.exit_code !== undefined) {
                        html += '<span class="doc-detail-exit">exit ' + r.exit_code + '</span>';
                    }
                    html += '</summary>';
                    if (r.output && r.output.trim()) {
                        html += '<pre class="doc-detail-output">' + esc(r.output.trim()) + '</pre>';
                    }
                    if (r.error && r.error.trim()) {
                        html += '<pre class="doc-detail-error">' + esc(r.error.trim()) + '</pre>';
                    }
                    html += '</details>';
                });
                res.innerHTML = html;
            }
        })
        .catch(function() {
            // Polling failure is not fatal
        });
    }

    // ========================================================================
    // ALERT FAILURES
    // ========================================================================
    var afData = [], afOpen = false;

    function loadAlertFailureCount() {
        engineFetch('/api/admin/alert-failure-count').then(function(data) { if(!data) return;
            if (data.Error) return;
            var badge = document.getElementById('af-badge');
            var countEl = document.getElementById('af-badge-count');
            if (!badge || !countEl) return;
            var count = data.count || 0;
            badge.style.display = '';
            if (count > 0) {
                badge.className = 'af-badge';
                countEl.textContent = count;
            } else {
                badge.className = 'af-badge clean';
                countEl.textContent = '';
            }
        }).catch(function() {});
    }

    function openAlertFailures() {
        afOpen = true;
        document.getElementById('af-body').innerHTML = '<div class="loading" style="padding:20px;">Loading...</div>';
        document.getElementById('af-results-count').textContent = '';
        document.getElementById('af-backdrop').classList.add('visible');
        document.getElementById('af-panel').classList.add('visible');
        loadAlertFailures();
    }

    function closeAlertFailures() {
        afOpen = false;
        document.getElementById('af-backdrop').classList.remove('visible');
        document.getElementById('af-panel').classList.remove('visible');
    }

    function loadAlertFailures() {
        engineFetch('/api/admin/alert-failures').then(function(data) { if(!data) return;
            if (data.Error) {
                document.getElementById('af-body').innerHTML = '<div style="color:#ef4444;padding:20px;text-align:center;">' + esc(data.Error) + '</div>';
                return;
            }
            afData = Array.isArray(data) ? data : [];
            renderAlertFailures();
        }).catch(function(e) {
            document.getElementById('af-body').innerHTML = '<div style="color:#ef4444;padding:20px;text-align:center;">Failed to load: ' + esc(e.message) + '</div>';
        });
    }

    function renderAlertFailures() {
        var body = document.getElementById('af-body');
        var countEl = document.getElementById('af-results-count');

        if (afData.length === 0) {
            countEl.textContent = '';
            body.innerHTML = '<div class="af-empty"><div class="af-empty-icon">&#10003;</div>No unresolved alert failures</div>';
            return;
        }

        countEl.textContent = afData.length + ' failure' + (afData.length !== 1 ? 's' : '');
        var html = '';
        afData.forEach(function(a) {
            var catCls = (a.alert_category || '').toLowerCase();
            if (catCls !== 'critical' && catCls !== 'warning' && catCls !== 'info') catCls = 'info';

            html += '<div class="af-card" id="af-card-' + a.queue_id + '">';
            html += '<div class="af-card-header">';
            html += '<span class="af-module-badge">' + esc(a.source_module) + '</span>';
            html += '<span class="af-category-badge ' + catCls + '">' + esc(a.alert_category) + '</span>';
            html += '<span class="af-card-title" title="' + esc(a.title) + '">' + esc(a.title) + '</span>';
            html += '</div>';

            if (a.error_message && !(a.error_message instanceof Object)) {
                html += '<div class="af-card-error">' + esc(a.error_message) + '</div>';
            }

            html += '<div class="af-card-footer">';
            html += '<div class="af-card-meta">';
            html += '<span>Retries: ' + (a.retry_count || 0) + '</span>';
            html += '<span>' + fmtTs(a.created_dttm) + '</span>';
            html += '</div>';
            html += '<button class="af-resend-btn" id="af-resend-' + a.queue_id + '" onclick="Admin.resendAlert(' + a.queue_id + ')">Resend</button>';
            html += '</div>';
            html += '</div>';
        });
        body.innerHTML = html;
    }

    function resendAlert(queueId) {
        var alertItem = null;
        for (var i = 0; i < afData.length; i++) {
            if (afData[i].queue_id === queueId) { alertItem = afData[i]; break; }
        }
        var alertTitle = alertItem ? alertItem.title : 'this alert';

        showConfirm(
            'Resend Alert',
            'Resend "' + alertTitle + '"? A new copy will be queued for delivery.',
            'Resend',
            'safe',
            function() {
                var btn = document.getElementById('af-resend-' + queueId);
                if (btn) {
                    btn.textContent = 'Pending\u2026';
                    btn.className = 'af-resend-btn pending';
                }
                engineFetch('/api/admin/alert-resend', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({ queue_id: queueId })
                }).then(function(data) { if(!data) return;
                    if (data.Error) {
                        if (btn) { btn.textContent = 'Resend'; btn.className = 'af-resend-btn'; }
                        showConfirm('Resend Failed', data.Error, 'OK', 'danger', function() {});
                        return;
                    }
                    loadAlertFailureCount();
                    if (afOpen) { setTimeout(loadAlertFailures, 600); }
                }).catch(function(e) {
                    if (btn) { btn.textContent = 'Resend'; btn.className = 'af-resend-btn'; }
                    showConfirm('Resend Failed', e.message, 'OK', 'danger', function() {});
                });
            }
        );
    }

    return{handleEngineEvent:handleEngineEvent,pageRefresh:pageRefresh,setFilter:setFilter,setWindow:setWindow,toggleProcess:toggleProcess,toggleDrain:toggleDrain,closeLog:closeLog,switchLogTab:switchLogTab,serviceControl:serviceControl,openEngineControls:openEngineControls,closeEngineControls:closeEngineControls,cancelConfirm:cancelConfirm,executeConfirm:executeConfirm,openMetadata:openMetadata,closeMetadata:closeMetadata,metaToggleRoot:metaToggleRoot,metaToggleMod:metaToggleMod,metaToggleComp:metaToggleComp,metaDescInput:metaDescInput,metaInsert:metaInsert,metaLoadHistory:metaLoadHistory,metaLoadObjects:metaLoadObjects,closeDetail:closeDetail,cancelInput:cancelInput,confirmInput:confirmInput,openGlobalConfig:openGlobalConfig,closeGlobalConfig:closeGlobalConfig,gcGo:gcGo,gcToggleMod:gcToggleMod,gcToggleRow:gcToggleRow,gcToggleBit:gcToggleBit,gcToggleAlertMode:gcToggleAlertMode,gcStartEdit:gcStartEdit,gcCancelEdit:gcCancelEdit,gcSaveEdit:gcSaveEdit,gcStartAdd:gcStartAdd,gcCancelAdd:gcCancelAdd,gcSubmitAdd:gcSubmitAdd,gcToggleActive:gcToggleActive,gcToggleInactive:gcToggleInactive,openSchedules:openSchedules,closeSchedules:closeSchedules,schedToggleMod:schedToggleMod,schedToggleRow:schedToggleRow,schedStartEdit:schedStartEdit,schedCancelEdit:schedCancelEdit,schedSaveField:schedSaveField,schedToggleMode:schedToggleMode,schedToggleConcurrent:schedToggleConcurrent,schedStartAdd:schedStartAdd,schedCancelAdd:schedCancelAdd,schedSubmitAdd:schedSubmitAdd,schedScriptSelected:schedScriptSelected,schedAddToggleMode:schedAddToggleMode,openDocPipeline:openDocPipeline,closeDocPipeline:closeDocPipeline,runDocPipeline:runDocPipeline,docTogglePill:docTogglePill,openAlertFailures:openAlertFailures,closeAlertFailures:closeAlertFailures,resendAlert:resendAlert};
})();
