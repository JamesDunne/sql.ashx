<%@ WebHandler Language="C#" Class="AdHocQuery.SqlServiceProvider" %>
<%@ Assembly Name="System.Core, Version=4.0.0.0, Culture=neutral, PublicKeyToken=b77a5c561934e089" %>
<%@ Assembly Name="System.Data, Version=4.0.0.0, Culture=neutral, PublicKeyToken=b77a5c561934e089" %>
/*
NOTE(jsd): Use these versions for .NET 2.0 to 3.5:
    Assembly Name="System.Core, Version=3.5.0.0, Culture=neutral, PublicKeyToken=b77a5c561934e089"
    Assembly Name="System.Data, Version=2.0.0.0, Culture=neutral, PublicKeyToken=b77a5c561934e089"
*/

// SQL Query Executor
// Designed and implemented by James S. Dunne (github.com/JamesDunne)
// on 2012-11-16

// Requires Newtonsoft.Json

#define NET_4_5

using System;
using System.Collections.Generic;
using System.Data;
using System.Data.SqlClient;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
#if NET_4_5
using System.Threading.Tasks;
#endif
using System.Web;
using Newtonsoft.Json;
using Newtonsoft.Json.Serialization;

namespace AdHocQuery
{
#if NET_4_5
    public class SqlServiceProvider : HttpTaskAsyncHandler
#else
    public class SqlServiceProvider : IHttpHandler
#endif
    {
        const string httpBasicAuth_Username = "username";
        const string httpBasicAuth_Password = "password";

        enum FormatMode
        {
            NoWhitespace,
            SimpleLines,
            Indented
        }

        struct Context
        {
            public readonly HttpRequest req;
            public readonly HttpResponse rsp;
            public readonly JsonTextWriter jtw;
            public readonly FormatMode pretty;

            public Context(HttpRequest req_, HttpResponse rsp_, JsonTextWriter jtw_, FormatMode pretty_)
            {
                req = req_;
                rsp = rsp_;
                jtw = jtw_;
                pretty = pretty_;
            }
        }

        public bool IsReusable { get { return true; } }

#if NET_4_5
        public override async Task ProcessRequestAsync(HttpContext context)
#else
        public void ProcessRequest(HttpContext context)
#endif
        {
            var req = context.Request;

            // Set up our default response headers:
            var rsp = context.Response;
            rsp.Buffer = true;
            rsp.TrySkipIisCustomErrors = true;
            rsp.ContentType = "application/json; charset=utf-8";
            rsp.ContentEncoding = Encoding.UTF8;

            // Create a JsonTextWriter to manually stream out the response as we can:
            using (var jtw = new JsonTextWriter(context.Response.Output))
            {
                FormatMode pretty = FormatMode.NoWhitespace;
                int prettyInt;
                if (Int32.TryParse(req.QueryString["pretty"], out prettyInt))
                {
                    if (prettyInt == 0)
                        pretty = FormatMode.NoWhitespace;
                    else if (prettyInt == 1)
                        pretty = FormatMode.Indented;
                    else if (prettyInt == 2)
                        pretty = FormatMode.SimpleLines;
                }

                if (pretty == FormatMode.Indented)
                {
                    jtw.Formatting = Formatting.Indented;
                    jtw.IndentChar = ' ';
                    jtw.Indentation = 2;
                }

                // Check authorization:
                string auth = req.Headers["Authorization"];
                if (auth == null || !auth.StartsWith("Basic "))
                {
                    rsp.StatusCode = 403;
                    jtw.WriteStartObject();
                    jtw.WritePropertyName("success");
                    jtw.WriteValue(false);
                    jtw.StartErrorsArray();
                    jtw.WriteErrorMessage("Unauthorized");
                    jtw.EndErrorsArray();
                    jtw.WriteEndObject();
                    return;
                }

                // Check the username:password
                string b64up = auth.Substring(6);
                if (b64up != Convert.ToBase64String(Encoding.ASCII.GetBytes(httpBasicAuth_Username + ":" + httpBasicAuth_Password)))
                {
                    rsp.StatusCode = 403;
                    jtw.WriteStartObject();
                    jtw.WritePropertyName("success");
                    jtw.WriteValue(false);
                    jtw.StartErrorsArray();
                    jtw.WriteErrorMessage("Unauthorized");
                    jtw.EndErrorsArray();
                    jtw.WriteEndObject();
                    return;
                }

                // Must be POST:
                if (req.HttpMethod != "POST")
                {
                    rsp.StatusCode = 402;
                    jtw.WriteStartObject();
                    jtw.WritePropertyName("success");
                    jtw.WriteValue(false);
                    jtw.StartErrorsArray();
                    jtw.WriteErrorMessage("HTTP method must be POST");
                    jtw.EndErrorsArray();
                    jtw.WriteEndObject();
                    return;
                }

                // Default to successful from here on out:
                rsp.StatusCode = 200;
                rsp.AddHeader("Access-Control-Allow-Origin", "*");

                var ctx = new Context(req, rsp, jtw, pretty);

                // Self-upgrade function; downloads latest version of files from github
                var toUpgrade = req.QueryString["$upgrade"];
                if (toUpgrade != null)
                {
                    // Make sure $upgrade is a filename:
                    if (toUpgrade.IndexOfAny(System.IO.Path.GetInvalidFileNameChars()) != -1)
                    {
                        rsp.StatusCode = 400;
                        jtw.WriteStartObject();
                        jtw.WritePropertyName("success");
                        jtw.WriteValue(false);
                        jtw.StartErrorsArray();
                        jtw.WriteErrorMessage("Bad value for $upgrade; expecting filename");
                        jtw.EndErrorsArray();
                        jtw.WriteEndObject();
                        return;
                    }

                    const string sourceURL = "https://raw.github.com/JamesDunne/sql.ashx/master/";
#if NET_4_5
                    string etag = null;
                    try
                    {
                        // Create an HTTP request to raw.github.com to download the latest version:
                        var ghrsp = await System.Net.HttpWebRequest.CreateHttp(sourceURL + toUpgrade).GetResponseAsync();
                        etag = ghrsp.Headers["ETag"];

                        // Find out the current directory for overwriting:
                        string thisPath = System.IO.Path.GetDirectoryName(context.Server.MapPath(req.AppRelativeCurrentExecutionFilePath));
                        string dlPath = System.IO.Path.Combine(thisPath, toUpgrade);

                        // Open the target file for overwriting:
                        using (var file = System.IO.File.Open(dlPath, FileMode.Create, FileAccess.Write, FileShare.None))
                        // Get the HTTP response:
                        using (var ghrspstr = ghrsp.GetResponseStream())
                        {
                            // Copy the HTTP stream to the local file:
                            await ghrspstr.CopyToAsync(file);
                        }
                    }
                    catch (Exception ex)
                    {
                        ReportException(ctx, ex);
                        return;
                    }

                    jtw.WriteStartObject();
                    jtw.WritePropertyName("success");
                    jtw.WriteValue(true);
                    jtw.WritePropertyName("upgraded");
                    jtw.WriteValue(toUpgrade);
                    jtw.WritePropertyName("etag");
                    jtw.WriteValue(etag);
                    jtw.WriteEndObject();
                    return;
#else
                    // TODO
                    jtw.WriteStartObject();
                    jtw.WritePropertyName("success");
                    jtw.WriteValue(false);
                    jtw.WritePropertyName("error");
                    jtw.WriteValue("TODO: implement");
                    jtw.WriteEndObject();
                    return;
#endif
                }

                try
                {
                    // Run the query text from the POST request body and serialize output as we read results from SQL:
#if NET_4_5
                    await RunQuery(ctx);
#else
                    RunQuery(ctx);
#endif
                }
                catch (Exception ex)
                {
                    ReportException(ctx, ex);
                }
            }
        }

        void ReportException(Context ctx, Exception ex)
        {
            ctx.rsp.StatusCode = 400;

            var jtw = ctx.jtw;
            jtw.WriteStartObject();

            jtw.WritePropertyName("success");
            jtw.WriteValue(false);

            jtw.StartErrorsArray();
            jtw.WriteErrorObjects(ex);
            jtw.EndErrorsArray();

            jtw.WriteEndObject();
        }

#if NET_4_5
        async Task RunQuery(Context ctx)
#else
        void RunQuery(Context ctx)
#endif
        {
            var req = ctx.req;
            var rsp = ctx.rsp;
            var jtw = ctx.jtw;

            // Read SQL query from HTTP request body:
#if NET_4_5
            string query = await new StreamReader(req.GetBufferedInputStream(), Encoding.UTF8, false).ReadToEndAsync();
#else
            string query = new StreamReader(req.InputStream, Encoding.UTF8, false).ReadToEnd();
#endif
            if (String.IsNullOrEmpty(query))
            {
                rsp.StatusCode = 400;
                jtw.WriteStartObject();
                jtw.WritePropertyName("success");
                jtw.WriteValue(false);
                jtw.StartErrorsArray();
                jtw.WriteErrorMessage("Empty POST body; expecting a SQL query");
                jtw.EndErrorsArray();
                jtw.WriteEndObject();
                return;
            }

            // Build the connection string:
            var csb = new SqlConnectionStringBuilder();
            csb.DataSource = req.QueryString["ds"];
            csb.InitialCatalog = req.QueryString["ic"];
            csb.ApplicationName = "sql.ashx";
            csb.AsynchronousProcessing = true;

            string uid = req.QueryString["uid"];
            if (uid != null)
            {
                csb.UserID = uid;
                csb.Password = req.QueryString["pwd"];
                csb.IntegratedSecurity = false;
            }
            else
                csb.IntegratedSecurity = true;

            int cmdTimeout = 30;
            int tmoutVal;
            string tmout = req.QueryString["tmout"];
            if ((tmout != null) && Int32.TryParse(tmout, out tmoutVal))
                cmdTimeout = tmoutVal;

            if (cmdTimeout <= 0) cmdTimeout = 30;

            using (var cn = new SqlConnection(csb.ToString()))
            using (var cmd = cn.CreateCommand())
            {
                long rowcount;
                if (!Int64.TryParse(req.QueryString["rowcount"], out rowcount))
                    rowcount = 100;
                if (rowcount < 0) rowcount = 0;

                cmd.CommandText = String.Format("SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;\r\nSET ROWCOUNT {0};\r\n{1}", rowcount, query);
                cmd.CommandType = CommandType.Text;
                cmd.CommandTimeout = cmdTimeout;

                // Use some stopwatch timers:
                System.Diagnostics.Stopwatch swOpen, swExec;

                // Connect to the SQL server:
                swOpen = System.Diagnostics.Stopwatch.StartNew();
                try
                {
#if NET_4_5
                    await cn.OpenAsync();
#else
                    cn.Open();
#endif
                    swOpen.Stop();
                }
                catch (Exception ex)
                {
                    swOpen.Stop();
                    ReportException(ctx, ex);
                    return;
                }

                // Start writing a response:
                jtw.WriteStartObject();

                // 'success' is wishy-washy here because a multi-statement query may contain successful results and also error results
                jtw.WritePropertyName("success");
                jtw.WriteValue(true);

                // Write server details:
                jtw.WritePropertyName("server");
                jtw.WriteStartObject();
                jtw.WritePropertyName("dataSource");
                jtw.WriteValue(cn.DataSource);
                jtw.WritePropertyName("database");
                jtw.WriteValue(cn.Database);
                jtw.WritePropertyName("version");
                jtw.WriteValue(cn.ServerVersion);
                jtw.WriteEndObject();

                // Execute the query:
                SqlDataReader dr = null;
                SqlException sqex = null;
                swExec = System.Diagnostics.Stopwatch.StartNew();
                try
                {
#if NET_4_5
                    dr = await cmd.ExecuteReaderAsync(CommandBehavior.CloseConnection | CommandBehavior.SequentialAccess);
#else
                    dr = cmd.ExecuteReader(CommandBehavior.CloseConnection | CommandBehavior.SequentialAccess);
#endif
                    swExec.Stop();
                }
                catch (SqlException ex)
                {
                    swExec.Stop();
                    sqex = ex;
                }

                // Write timing information:
                jtw.WritePropertyName("timing");
                jtw.WriteStartObject();
                jtw.WritePropertyName("open");
                jtw.WriteValue(swOpen.ElapsedMilliseconds);
                jtw.WritePropertyName("exec");
                jtw.WriteValue(swExec.ElapsedMilliseconds);
                jtw.WritePropertyName("total");
                jtw.WriteValue((long)(swOpen.Elapsed + swExec.Elapsed).TotalMilliseconds);
                jtw.WriteEndObject();

                // Write results array:
                jtw.WritePropertyName("results");
                jtw.WriteStartArray();
                if (ctx.pretty == FormatMode.SimpleLines) jtw.WriteWhitespace("\n");

                if (sqex != null)
                {
                    // Start result object:
                    jtw.WriteStartObject();

                    jtw.WritePropertyName("success");
                    jtw.WriteValue(false);

                    jtw.StartErrorsArray();
                    jtw.WriteErrorObjects(sqex);
                    jtw.EndErrorsArray();

                    jtw.WriteEndObject();

                    // If the first statement fails, no others after it are executed.
                    goto endOfResults;
                }

                // Read the results:
                using (dr)
                {
                    int lastRecordsAffected = 0;
                    // Read multiple result-sets:
                    bool hasNextResult = true;
                    while (hasNextResult)
                    {
                        // Start result object:
                        jtw.WriteStartObject();

                        jtw.WritePropertyName("success");
                        jtw.WriteValue(true);

                        // Report number of records affected for insert/update/exec statements, if applicable.
                        // Will be -1 for SELECT queries
                        jtw.WritePropertyName("recordsAffected");
                        if (dr.RecordsAffected == -1)
                        {
                            jtw.WriteValue(-1);
                        }
                        else
                        {
                            jtw.WriteValue(dr.RecordsAffected - lastRecordsAffected);
                        }

                        lastRecordsAffected = dr.RecordsAffected;

                        // Write column metadata:
                        jtw.WritePropertyName("columns");
                        jtw.WriteStartArray();
                        if (ctx.pretty == FormatMode.SimpleLines) jtw.WriteWhitespace("\n");
                        var dst = dr.GetSchemaTable();
#if false
                        for (int i = 0; i < dst.Columns.Count; ++i)
                            jtw.WriteValue(String.Format("{0} : {1}", dst.Columns[i].ColumnName, dst.Columns[i].DataType.FullName));
#else
                        for (int i = 0; i < dr.FieldCount; ++i)
                        {
                            var dstRow = dst.Rows[i];
                            string colname = (string)dstRow["ColumnName"];
                            string typename = (string)dstRow["DataTypeName"];
                            int colsize = (int)dstRow["ColumnSize"];
                            string precision = String.Empty;
                            switch (typename)
                            {
                                case "varchar":
                                case "nvarchar":
                                case "varbinary":
                                case "binary":
                                case "char":
                                case "nchar":
                                    precision = String.Format("({0})", colsize == Int32.MaxValue ? "max" : colsize.ToString());
                                    break;
                                case "datetime2":
                                case "datetimeoffset":
                                    precision = String.Format("({0})", dstRow["NumericScale"]);
                                    break;
                                default:
                                    break;
                            }
                            bool allowNull = (bool)dstRow["AllowDBNull"];
                            if (!allowNull) precision += " NOT NULL";
                            jtw.WriteValue(String.Format("[{0}] {1}{2}", colname, typename, precision));
                            if (ctx.pretty == FormatMode.SimpleLines) jtw.WriteWhitespace("\n");
                        }
#endif
                        jtw.WriteEndArray();
                        if (ctx.pretty == FormatMode.SimpleLines) jtw.WriteWhitespace("\n");

                        jtw.WritePropertyName("hasRows");
                        jtw.WriteValue(dr.HasRows);

                        if (dr.HasRows)
                        {
                            // Serialize row data:
                            jtw.WritePropertyName("rows");
                            jtw.WriteStartArray();
                            if (ctx.pretty == FormatMode.SimpleLines) jtw.WriteWhitespace("\n");
#if NET_4_5
                            while (await dr.ReadAsync())
#else
                            while (dr.Read())
#endif
                            {
                                jtw.WriteStartArray();
                                for (int i = 0; i < dr.FieldCount; ++i)
                                {
                                    object value = dr.GetValue(i);
                                    try
                                    {
                                        if (value == null || value == DBNull.Value)
                                            jtw.WriteNull();
                                        else
                                            jtw.WriteValue(value);
                                    }
                                    catch
                                    {
                                        // Dunno what happened, but keep going:
                                        jtw.WriteUndefined();
                                    }
                                }
                                jtw.WriteEndArray();
                                if (ctx.pretty == FormatMode.SimpleLines) jtw.WriteWhitespace("\n");
                            }
                            jtw.WriteEndArray();
                            if (ctx.pretty == FormatMode.SimpleLines) jtw.WriteWhitespace("\n");
                        }

                        // End of current result object:
                        jtw.WriteEndObject();
                        if (ctx.pretty == FormatMode.SimpleLines) jtw.WriteWhitespace("\n");

                        // Check if there's another result:
                        bool retry = false;
                        do
                        {
                            try
                            {
                                // NextResult() throws a SqlException to represent the errors of the next statement.
#if NET_4_5
                                hasNextResult = await dr.NextResultAsync();
#else
                                hasNextResult = dr.NextResult();
#endif
                                retry = false;
                            }
                            catch (Exception ex)
                            {
                                // Write out a results object to represent the statement's errors:
                                jtw.WriteStartObject();
                                jtw.WritePropertyName("success");
                                jtw.WriteValue(false);
                                jtw.StartErrorsArray();
                                jtw.WriteErrorObjects(ex);
                                jtw.EndErrorsArray();
                                jtw.WriteEndObject();
                                retry = true;
                            }
                        } while (retry);
                    }
                }

            endOfResults:
                // End of results array:
                jtw.WriteEndArray();
                // End of response object:
                jtw.WriteEndObject();
            }
        }
    }

    public static class JsonTextWriterExtensions
    {
        public static void StartErrorsArray(this JsonTextWriter jtw)
        {
            jtw.WritePropertyName("errors");
            jtw.WriteStartArray();
        }

        public static void EndErrorsArray(this JsonTextWriter jtw)
        {
            jtw.WriteEndArray();
        }

        public static void WriteErrorMessage(this JsonTextWriter jtw, string message)
        {
            jtw.WriteStartObject();
            jtw.WritePropertyName("message");
            jtw.WriteValue(message);
            jtw.WriteEndObject();
        }

        public static void WriteErrorObjects(this JsonTextWriter jtw, Exception ex)
        {
            SqlException sqex = ex as SqlException;
            if (sqex != null)
            {
                foreach (SqlError err in sqex.Errors)
                {
                    jtw.WriteStartObject();
                    jtw.WritePropertyName("message");
                    jtw.WriteValue(err.Message);
                    jtw.WritePropertyName("number");
                    jtw.WriteValue(err.Number);
                    jtw.WritePropertyName("line");
                    jtw.WriteValue(err.LineNumber);
                    jtw.WritePropertyName("procedure");
                    jtw.WriteValue(err.Procedure);
                    jtw.WritePropertyName("server");
                    jtw.WriteValue(err.Server);
                    jtw.WriteEndObject();
                }
            }
            else
            {
                jtw.WriteStartObject();
                jtw.WritePropertyName("message");
                jtw.WriteValue(ex.Message);
                jtw.WritePropertyName("type");
                jtw.WriteValue(ex.GetType().FullName);
                jtw.WriteEndObject();
            }
        }
    }
}