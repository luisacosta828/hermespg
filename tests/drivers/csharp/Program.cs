using System;
using Npgsql;

class Program
{
    static async Task<int> Main(string[] args)
    {
        var host = Environment.GetEnvironmentVariable("PGHOST") ?? "127.0.0.1";
        var port = Environment.GetEnvironmentVariable("PGPORT") ?? "6432";
        var user = Environment.GetEnvironmentVariable("PGUSER") ?? "postgres";
        var password = Environment.GetEnvironmentVariable("PGPASSWORD") ?? "";
        var database = Environment.GetEnvironmentVariable("PGDATABASE") ?? "postgres";

        var connString = $"Host={host};Port={port};Username={user};Password={password};Database={database};SSL Mode=Disable;";
        Console.WriteLine($"[C# / .NET] Connecting to HermesPG at {host}:{port} via Npgsql...");

        try
        {
            await using var dataSource = NpgsqlDataSource.Create(connString);
            await using var conn = await dataSource.OpenConnectionAsync();

            // 1. Simple query
            Console.WriteLine("[C# / .NET] 1. Testing Simple Query (SELECT 1)...");
            await using (var cmd = new NpgsqlCommand("SELECT 1;", conn))
            {
                var result = Convert.ToInt32(await cmd.ExecuteScalarAsync());
                if (result != 1) throw new Exception($"Expected 1, got {result}");
            }

            // 2. Extended query with parameters (Parse, Bind, Execute)
            Console.WriteLine("[C# / .NET] 2. Testing Extended Query Protocol (SELECT @p1 + @p2)...");
            await using (var cmd = new NpgsqlCommand("SELECT @p1::int + @p2::int;", conn))
            {
                cmd.Parameters.AddWithValue("p1", 20);
                cmd.Parameters.AddWithValue("p2", 22);
                var total = Convert.ToInt32(await cmd.ExecuteScalarAsync());
                if (total != 42) throw new Exception($"Expected 42, got {total}");
            }

            // 3. Transaction block
            Console.WriteLine("[C# / .NET] 3. Testing Transaction Block (BEGIN -> SELECT -> COMMIT)...");
            await using (var tx = await conn.BeginTransactionAsync())
            {
                await using (var cmd = new NpgsqlCommand("SELECT 100;", conn, tx))
                {
                    var txVal = Convert.ToInt32(await cmd.ExecuteScalarAsync());
                    if (txVal != 100) throw new Exception($"Expected 100, got {txVal}");
                }
                await tx.CommitAsync();
            }

            Console.WriteLine("[C# / .NET] ✅ SUCCESS: All Npgsql tests passed with HermesPG!");
            return 0;
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"[C# / .NET] ❌ FAILED: {ex.Message}");
            return 1;
        }
    }
}
