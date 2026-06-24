create or alter proc [dbo].[p_TempText] as
	select * from (values
		(1, 'A', 'alpha'),
		(2, 'B', 'beta'),
		(3, 'C', 'gamma')
	) t (Num, Code, GreekName);

	select * from (values
		('James', 4505076),
		('Mary', 2845637),
		('Michael', 4359450),
		('Patricia', 1531355),
		('John', 4204996),
		('Jennifer', 1471356)
	) t (FirstName, Balance);
go

-- Change database setting to allow using xp_cmdshell.
EXECUTE sp_configure 'show advanced options', 1;
RECONFIGURE;
EXECUTE sp_configure 'xp_cmdshell', 1;
RECONFIGURE;

declare @command_string nvarchar(4000) = concat(
	'sqlcmd ',
	'-S"', @@SERVERNAME, '" ', -- server
	'-q"EXEC [', db_name(), '].[dbo].[p_TempText]" ', -- "cmdline query"
	'-s"~" ', -- column_separator
	'-W' -- remove trailing spaces
);

declare @Lines table (Line int identity, String nvarchar(MAX));

insert @Lines exec xp_cmdshell @command_string;

declare @Values table (ValueNumber int identity, Line int, [Value] nvarchar(MAX));

insert @Values
select r.Line, v.[Value]
from @Lines r
cross apply string_split(r.String, '~') v;

with stat as (
	select Line, MIN(ValueNumber) as FirstCol 
	from @Values 
	group by Line
)
select p.Line, p.ValueNumber - s.FirstCol + 1 as [Column], p.[Value]
from @Values p
join stat s on p.Line = s.Line;
go

drop proc if exists [dbo].[p_TempText];
go

