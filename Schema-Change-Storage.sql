-- ----------------------------------------------------------------------------
-- ===== SCHEMA CHANGE STORAGE - INSTRUCTIONS ===== --
-- Run this script in the database you want schema changes stored.
-- It can be a single database or multiple.
-- If it's single, all databases transmit their changes there.
-- If it's multiple, then each one stores only its own changes.
-- ----------------------------------------------------------------------------

/*
	-- ===== Rollback changes ===== --
	disable trigger [t_SchemaChange] on database;
	-- enable trigger [t_SchemaChange] on database;
	drop trigger if exists [t_SchemaChange] on database;
	drop view if exists [SchemaChange].[v_SchemaChange];
	drop proc if exists [SchemaChange].[p_Save];
	drop proc if exists [SchemaChange].[p_StatusReport];
	-- DANGER: do not drop the SchemaChange tables. Loss of data!
*/

-- disable the trigger so that it doesn't fire while running this script.
if exists (select * from sys.triggers where name = 't_SchemaChange' and parent_class_desc = 'DATABASE')
	disable trigger [t_SchemaChange] on database;

if SCHEMA_ID('SchemaChange') is null exec ('create schema [SchemaChange] authorization [dbo]');

if OBJECT_ID('[SchemaChange].[User]') is null
	create table [SchemaChange].[User] (
		UserID int not null identity constraint PK_SchemaChange_User primary key,
		LoginName sysname not null,
		UserName sysname not null,
		constraint UX_SchemaChange_User unique (LoginName, UserName)
	);

if OBJECT_ID('[SchemaChange].[Object]') is null
	create table [SchemaChange].[Object] (
		ObjectID int not null identity constraint PK_SchemaChange_Object primary key,
		ServerName sysname not null,
		DatabaseName sysname not null,
		ObjectName sysname not null,
		constraint UX_SchemaChange_Object unique (ServerName, DatabaseName, ObjectName)
	);

if OBJECT_ID('[SchemaChange].[Event]') is null
	create table [SchemaChange].[Event] (
		EventID int not null identity
			constraint PK_SchemaChange_Event primary key,
		TriggerEventType int not null,
		PostTime datetime2(2) not null, -- local
		UserID int not null
			constraint FK_SchemaChange_UserID
			references [SchemaChange].[User] (UserID),
		ObjectID int not null
			constraint FK_SchemaChange_ObjectID
			references [SchemaChange].[Object] (ObjectID),
		AlterTableActionList xml not null,
		CommandText nvarchar(MAX)
	);
go

-- ----------------------------------------------------------------------------
-- SELECT TOP 5 * FROM [SchemaChange].[v_SchemaChange] ORDER BY 1 DESC
create or alter view [SchemaChange].[v_SchemaChange] as
	SELECT
		e.EventID,
		e.PostTime,
		u.LoginName,
		u.UserName,
		tet.[type_name] as TriggerEventTypeName,
		o.DatabaseName,
		o.ObjectName,
		e.CommandText,
		e.AlterTableActionList
	FROM [SchemaChange].[Event] e
	join sys.trigger_event_types tet on e.TriggerEventType = tet.[type]
	join [SchemaChange].[User] u on e.UserID = u.UserID
	join [SchemaChange].[Object] o on e.ObjectID = o.ObjectID;
go

-- ----------------------------------------------------------------------------
-- Reports on the status of the schema change and schema validation features.
--     EXEC [SchemaChange].[p_StatusReport];
create or ALTER proc [SchemaChange].[p_StatusReport] as
	select top 0 db_id() as database_id, is_disabled into #triggers from sys.triggers;

	insert into #triggers exec sp_msforeachdb N'use ?; 
		select db_id(), is_disabled
		from sys.triggers
		where name = ''t_SchemaChange'' and parent_class_desc = ''DATABASE'';';

	select top 0 db_id() as database_id into #procedures from sys.procedures;

	insert into #procedures 
	exec sp_msforeachdb N'use ?; 
		select db_id()
		from sys.procedures
		where name = ''p_SaveSchemaChange''
			and OBJECT_SCHEMA_NAME(object_id) = ''SchemaChange'';';

	select top 0 DB_ID() as database_id, [rows] into #partitions from sys.partitions;

	insert #partitions
	exec sp_MSforeachdb 'use ?; 
		select DB_ID(), rows 
		from sys.partitions 
		where object_id = OBJECT_ID(''SchemaValidation.Rule'') and index_id = 1;';

	declare @StorageCount int = (select count(*) from #procedures);

	select d.name as [Database_Name], 
		case t.is_disabled
			when 0 then 'Active'
			when 1 then 'Deactivated'
			else 'Not Installed'
			end as Transmits,
		case
			when s.database_id is null then ''
			when @StorageCount = 1 then 'Single'
			else 'Multiple'
			end as Storage,
		isnull(cast(r.[rows] as varchar(50)), '') as Validation_Rule_Count
	from sys.databases d
	left join #triggers t on t.database_id = d.database_id 
	left join #procedures s on s.database_id = d.database_id 
	left join #partitions r on r.database_id = d.database_id
	where d.owner_sid <> 0x01
	order by d.name;
go

-- ----------------------------------------------------------------------------
-- This proc gets called by a database trigger in various databases.
-- Those triggers are fired by schema changes.
-- This proc records the schema change event in a set of tables.
create or alter proc [SchemaChange].[p_Save] 
	@DatabaseName sysname,
	@EventData xml
as
	set nocount on;

	declare
		@TriggerEventTypeName nvarchar(64),
		@PostTime datetime2(2),
		@LoginName sysname,
		@UserName sysname,
		@SchemaName sysname,
		@ObjectName sysname,
		@AlterTableActionList xml,
		@CommandText nvarchar(MAX);

	select
		@TriggerEventTypeName = c.value('EventType[1]', 'nvarchar(64)'),
		@PostTime = c.value('PostTime[1]', 'datetime2(2)'),
		@LoginName = c.value('LoginName[1]', 'sysname'),
		@UserName = c.value('UserName[1]', 'sysname'),
		@SchemaName = c.value('SchemaName[1]', 'sysname'),
		@ObjectName = c.value('ObjectName[1]', 'sysname'),
		@AlterTableActionList = c.query('AlterTableActionList/*'),
		@CommandText = c.value('(TSQLCommand/CommandText)[1]', 'nvarchar(MAX)')
	from @EventData.nodes('EVENT_INSTANCE') t(c);

	set @ObjectName = CONCAT(@SchemaName + '.', @ObjectName);

	insert [SchemaChange].[User] (LoginName, UserName)
	select @LoginName, @UserName
	except
	select LoginName, UserName 
	from [SchemaChange].[User] WITH (HOLDLOCK, UPDLOCK); 
	-- HOLDLOCK and UPDLOCK prevent deadlocks when using INSERT EXCEPT.

	insert [SchemaChange].[Object] (ServerName, DatabaseName, ObjectName)
	select @@SERVERNAME, @DatabaseName, @ObjectName
	except
	select ServerName, DatabaseName, ObjectName
	from [SchemaChange].[Object] WITH (HOLDLOCK, UPDLOCK);

	insert [SchemaChange].[Event] (
		TriggerEventType,
		PostTime,
		UserID,
		ObjectID,
		AlterTableActionList,
		CommandText
	)
	select
		t.[type] as TriggerEventType,
		@PostTime,
		u.UserID,
		o.ObjectID,
		@AlterTableActionList,
		@CommandText
	from sys.trigger_event_types t
	cross join [SchemaChange].[User] u
	cross join [SchemaChange].[Object] o
	where t.[type_name] = @TriggerEventTypeName
		and u.LoginName = @LoginName 
		and u.UserName = @UserName
		and o.ServerName = @@SERVERNAME
		and o.DatabaseName = @DatabaseName
		and o.ObjectName = @ObjectName;

	return SCOPE_IDENTITY();
go

-- re-enable the trigger now that this script is complete.
if exists (select * from sys.triggers where name = 't_SchemaChange' and parent_class_desc = 'DATABASE')
	enable trigger [t_SchemaChange] on database;
go


