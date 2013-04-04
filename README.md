sql.ashx
========

SQL Query Executor backend handler for ASP.NET with an HTML5 single-page user interface.

What is it?
===========
This project consists of exactly two important files: `sql.ashx` and `sqlui.html`

The `sql.ashx` file is a simple HTTP handler contained in a single-file deployment package that is used to execute SQL
queries and commands against a MS SQL Server database (2005 or later) and return JSON-formatted response objects for the
HTML UI to consume. It is essentially a self-contained web service.

The `sqlui.html` file is a self-contained HTML5 single-page user interface for talking to `sql.ashx` and executing the
SQL queries that you type in. It also handles server/database connection details, time-outs, tabular formatting of
results, and even comes with very productive keyboard shortcuts.

The two files are best hosted on an internal (non-public) web services ASP.NET host running some version of IIS. You
certainly do not want to host a SQL querying tool on a public web site.

Deployment
==========
Deployment is as simple as copying up two files to your ASP.NET host directory: `sql.ashx`, `sqlui.html`.

Both files are self-contained with no external dependencies except for `Newtonsoft.Json 4.5.11` for JSON serialization.
You'll want to obtain this DLL file via NuGet and copy it to the `bin/` directory of the ASP.NET application.

The `*.ashx` handler mapping is required to be set up in order for `sql.ashx` to serve requests with. The default IIS
configuration (IIS versions 6, 7, and 8) should all work out of the box. The `sqlui.html` file must be served as regular
HTML5 content.

Important Notes
===============

The `sql.ashx` handler is "protected" from unauthorized access via the HTTP Basic Authentication scheme. There is a
default username and password pair that are hard-coded. Look to line 41 (as of the time of this writing) to modify the
two string values `httpBasicAuth_Username` and `httpBasicAuth_Password` to suit your needs.

If Integrated Security connection mode is desired, be aware that the handler connects to the database via the identity
of the application pool of the hosting ASP.NET site.
