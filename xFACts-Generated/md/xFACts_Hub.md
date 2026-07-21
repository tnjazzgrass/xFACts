# xFACts Secrets Revealed

*Everything you wanted to know about xFACts but were afraid to query*

What Is This Thing?

xFACts is an enterprise IT operations platform that watches over the systems and processes that keep Frost Arnett running. It monitors servers, tracks jobs, catches problems, and tells people about them — usually before those people notice something is wrong.

That's the corporate answer. Here's the real one.

xFACts is the thing that pings you 25 times in rapid succession at 1:45 AM, causing your dog to scowl at you from the foot of the bed where you were sound asleep moments before. It's the dashboard that shows you exactly which index rebuild is running right now and how long it's been going. It's the reason you found out about the disk space problem *before* the server ran out. And it's the webpage that lets you see all of this without opening SQL Server Management Studio or writing a single query.

If you've ever used the Control Center — the website at `http://fa-sqldbb:8085` — you've used xFACts. The Control Center is the front door. Behind it is a SQL Server database, an orchestration engine, a collection of PowerShell scripts, and a whole lot of configuration that makes all of it work together.

This documentation explains how.






How We Got Here

The name xFACts — External Frost-Arnett Company Transaction Services — originally belonged to a Microsoft Access database that Matt Kussoff built years ago. The "Apps Toolkit" automated common IT tasks like test data generation, API calls, and job monitoring. It was clever, it was useful, and it lived on a single desktop. Extending it to anyone else was... not straightforward.

The idea of rebuilding it as something everyone could access had been floating around for years. It showed up on annual reviews. It came up in conversations. It sat comfortably on the list of "things we really should get around to doing someday."

Then in December of 2025, a routine audit meeting with Brandon Gilbert and Dianne Harrell of Business Intelligence regarding a noticeable group of consumers whose notice strategies appeared to have not executed uncovered something more interesting: Five Debt Manager job flows hadn't run at all on the last day of November for some unknown reason. Not one of them. Roughly a hundred jobs in all. And nobody had noticed until the gaps surfaced several weeks later.


That shouldn't happen. Technically there was a daily email that reported everything that ran overnight. But if you've ever seen that email, you understand how a few missing flows could get lost in a wall of green and a few red lines. It's the kind of thing where you give it a quick glance, see mostly good news, and move on with your morning.


That meeting ended with a simple goal: we need a way to know when our flows don't fire. Something that doesn't rely on reading a massive email. Something that just *tells* you.

So it started with one question: "Did our jobs run last night?" Our good friend Claude helped us build out a SQL database that could track overnight activity. That first conversation turned into a table, then a monitoring script, then an alert, then a dashboard, then... well, then it kind of kept going.

Server health monitoring showed up because "while we're here, let's track disk space too." Backup tracking came next because finding out your backup failed shouldn't require digging through SQL Agent history. Extended Events capture happened because someone asked "can we track blocking?" and the answer was yes. Index maintenance happened because doing it manually during off-hours was getting old.

Somewhere in there, the original Access database's name got borrowed — with its creator's blessing — and applied to a platform that had outgrown the original vision by a fair margin. Same name, same spirit, very different scale.


**The philosophy:** Build exactly what you need. If a tool solves your problem, great. If it gives you 200 features and none of them quite solve your problem, build the one that does. xFACts exists because the specific questions we needed answered weren't being answered by the tools we had.







The Big Picture

At the highest level, xFACts has four layers. Everything the platform does flows through them:




The Engine

Orchestrator

→

The Modules

Collectors & Monitors

→

The Megaphones

Teams & Jira



&harr;



The Window

Control Center


Everything xFACts does flows through these four layers


**The Engine** is the Master Orchestrator — a continuously running service that wakes up every few seconds, checks what needs to run, runs it, logs what happened, and goes back to sleep. It doesn't know or care what the individual modules do. It just makes sure they run on time. His friends just call him Mo.

**The Modules** are where the actual work happens. Each module is responsible for one area: server health, backup tracking, job flow monitoring, batch processing, file arrivals, index maintenance. Modules collect data, store it, evaluate it against thresholds, and decide if someone needs to know about something.

**The Megaphones** are Teams and Jira. When a module decides something needs attention, it queues a message for delivery. Dedicated queue processors pick up those messages and send them out. Teams for real-time notifications. Jira for issues that need a ticket and a follow-up.

**The Window** is the Control Center — the web interface where all of this becomes visible. Every module has a corresponding dashboard page. You can see what's running, what's broken, what happened yesterday, and what's coming up next. No SQL required.

The database sits in the middle of all of it. Every module writes to it. The Control Center reads from it. The orchestrator coordinates through it. Configuration lives in it. History is preserved in it. It's the single source of truth for everything xFACts knows.






The Pattern That Repeats Everywhere

Once you see it, you can't unsee it. Almost every module in xFACts follows the same four-step cycle:


Collect
→
Store
→
Evaluate
→
Alert


**Collect** — A PowerShell script reaches out to a server, a database, an SFTP location, or an API. It gathers the current state of whatever it's responsible for monitoring.

**Store** — That data gets written into xFACts tables. Not a summary, not an aggregate — the actual data. When did this backup complete? What was the disk free space at 2:47 PM? Which jobs ran and which didn't? It's all captured.

**Evaluate** — The data gets compared against configured thresholds. Is that disk below 15%? Has that batch been running for more than two hours? Did that file fail to arrive by its escalation time? These aren't hardcoded values — they're stored in configuration tables, adjustable at runtime without touching any code.

**Alert** — If evaluation finds something worth reporting, a message gets queued for Teams, a ticket gets queued for Jira, or both. The alerts include the context: what happened, when, and where to look.

This cycle runs continuously. Every few seconds, the orchestrator checks if any module is due for its next cycle. When it is, the pattern repeats. All day. All night. Weekends. Holidays. Mo doesn't take vacations.


**Why this matters:** If you understand this pattern, you understand every module in xFACts. The specifics change — what's being collected, what the thresholds are, who gets the alert — but the structure is always the same. Learn it once, apply it everywhere.







The Cast of Characters

xFACts is organized into modules. Each one owns a piece of the monitoring landscape and minds its own business. They share the same database, the same orchestrator, and the same alert delivery system, but otherwise they're independent. You can add a new module without touching the existing ones. You can disable a module without breaking anything else. That's the whole point.










How It All Connects

The Orchestrator
Every process in xFACts is registered in a single table called ProcessRegistry. Each row defines what to run, how often to run it, and what order to run it in relative to everything else. The orchestrator — a PowerShell service running on FA-SQLDBB — reads this table on a continuous heartbeat, launches whatever is due, and logs the results.

This is important because it means *nothing is hardcoded*. Want to temporarily disable backup monitoring during a maintenance window? Change a flag in the registry. Want to adjust how often disk space gets checked? Update the interval. Want to add an entirely new monitoring process? Insert a row. No code changes. No service restarts. The orchestrator adapts.

The Database
The xFACts database lives on the DMPRODAG Availability Group, with DM-PROD-DB as the primary and DM-PROD-REP as the secondary. It's organized into schemas that map to modules: `Orchestrator`, `ServerOps`, `JobFlow`, `BatchOps`, `BIDATA`, `FileOps`, `Teams`, `Jira`, `DeptOps`, and `dbo` for the shared infrastructure that ties them all together.

The schemas aren't just organizational — they're boundaries. A module's tables, procedures, and triggers live in its schema. Cross-schema references exist where they need to (every module talks to Teams, most talk to Jira), but modules don't reach into each other's business tables. If JobFlow needs to send an alert, it queues it for Teams delivery. The integration modules handle the rest.

GlobalConfig
Almost everything that can be adjusted lives in one table: `dbo.GlobalConfig`. Alert thresholds, feature toggles, timing windows, display settings — if a value might ever need to change without a code deployment, it's in GlobalConfig. Both the backend scripts and the Control Center read from it, which means a single configuration change can affect monitoring behavior and dashboard display simultaneously.

The Split Deployment
The database lives on the Availability Group. The orchestrator and Control Center run on FA-SQLDBB. This is deliberate. Collection scripts, web serving, and orchestration overhead happen on a separate server from the production database workload. The only thing that touches the AG is the data itself — reads and writes. All the processing happens elsewhere.

This matters because one of the first questions anyone asks about a monitoring platform is "how much overhead does it add to the servers it's monitoring?" The answer for xFACts is: very little, because the heavy lifting happens somewhere else.






The Technology Stack

Nothing exotic. Nothing that requires a separate license. Just tools that were already available, applied with some determination and a lot of help from an AI that only says "you can't do that" about twice a year.

| Component | Technology | What It Does |
| --- | --- | --- |
| Database | SQL Server 2017 Enterprise | The brain. All data, configuration, and history lives here on the DMPRODAG Availability Group. |
| Orchestrator | PowerShell + NSSM | The heartbeat. A PowerShell script running as a Windows service, continuously scheduling and executing all monitoring processes. |
| Collection Scripts | PowerShell 5.1 | The hands. Scripts that reach out via WinRM, SFTP, REST APIs, and SQL queries to gather data from across the environment. |
| Control Center | Pode (PowerShell Web Framework) | The face. A lightweight web server that turns database queries into dashboards. Also runs as an NSSM service on FA-SQLDBB. |
| Monitoring | Extended Events + DMVs | The eyes and ears. SQL Server's built-in lightweight instrumentation, centrally collected and stored. |
| Alerting | Teams Webhooks + Jira REST API | The megaphones. Adaptive Cards for real-time notifications, automated tickets for follow-up items. |
| Visualization | Chart.js | The charts. Client-side rendering for trend lines, utilization gauges, and historical graphs. |
| Authentication | Windows AD (fac.local) | The bouncer. Same credentials you use to log into your computer. |


The entire xFACts platform — every script, every page, every configuration file — lives in three folders on FA-SQLDBB plus one database on the AG. That's it. No application servers, no containers, no build pipelines. Just PowerShell, SQL, and stubbornness.






The Philosophy

xFACts was not built by a team of developers following an agile methodology with sprint planning and daily standups. It was built by people who got tired of finding out about problems after everyone else already knew.

That origin shapes everything about how the platform works:

**Build what you need, not what a vendor sells you.** Commercial monitoring tools give you 200 dashboards and none of them answer your specific question. xFACts has fewer dashboards, and every single one was built because someone needed that exact view of that exact data.

**Capture everything, display what matters.** The database stores detailed history — every backup file, every Extended Events session, every index rebuild. The Control Center shows you the summary. When you need the details, they're there. When you don't, they're not in the way.

**Configuration over code.** Thresholds, schedules, feature flags, alert routing — all stored in database tables. Changing behavior should never require editing a script and redeploying. Change a value, and the next cycle picks it up.

**Alerts should be actionable.** If an alert doesn't tell you what happened and where to look, it's noise. Every xFACts alert includes context. "Disk space is low" isn't helpful. "E: drive on DM-PROD-DB is at 12% (31 GB free)" is.

**The best documentation is the system itself.** Which is why you're reading this inside the Control Center, the same place you go to actually use the platform. No context-switching. No hunting through a wiki. Everything in one place.


If you can dream it, we can probably build it here. That's not marketing — it's an invitation. If you have a manual process, a monitoring gap, or a report that would be easier as a dashboard, talk to the Applications Team. The modular architecture means adding new functionality doesn't require touching anything that already works.







Where to Start

If you're reading this for the first time, here are some suggested paths depending on what you're after:

**I just want to understand the big picture.** You're basically done. The sections above cover what xFACts is, how it's organized, and the pattern everything follows. Scroll back up to *The Cast of Characters* and click on anything that sounds interesting.

**I want to understand how a specific module works.** Click on it in the grid above. Each module page tells the full story: what problem it solves, how it works, what you see in the Control Center, and how to troubleshoot it.

**I need to maintain or modify something.** Start with the relevant module page for context, then follow the link to its Reference page for technical details — table schemas, script documentation, and complete DDL.

**I want to understand the infrastructure that ties everything together.** Start with The Engine Room. That covers the orchestrator, version tracking, credential management, and protection mechanisms.

**I want to know how the website works.** Head to The Control Center page for architecture, setup, and technical reference.
