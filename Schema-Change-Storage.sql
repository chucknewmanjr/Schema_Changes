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
	drop proc if exists [SchemaChange].[p_FindSchemaChange];
	drop proc if exists [SchemaChange].[p_SaveSchemaChange];
	-- DANGER: do not drop the SchemaChange.SchemaChange tables. Loss of data!
*/

-- disable the trigger so that it doesn't fire while running this script.
if exists (select * from sys.triggers where name = 't_SchemaChange' and parent_class_desc = 'DATABASE')
	disable trigger [t_SchemaChange] on database;

if SCHEMA_ID('SchemaChange') is null exec ('create schema [SchemaChange] authorization [dbo]');

if OBJECT_ID('[SchemaChange].[SchemaChangeUser]') is null
	create table [SchemaChange].[SchemaChangeUser] (
		SchemaChangeUserID int not null identity constraint PK_SchemaChange_SchemaChangeUser primary key,
		LoginName sysname not null,
		UserName sysname not null,
		constraint UX_SchemaChange_SchemaChangeUser unique (LoginName, UserName)
	);

if OBJECT_ID('[SchemaChange].[SchemaChangeObject]') is null
	create table [SchemaChange].[SchemaChangeObject] (
		SchemaChangeObjectID int not null identity constraint PK_SchemaChange_SchemaChangeObject primary key,
		ServerName sysname not null,
		DatabaseName sysname not null,
		ObjectName sysname not null,
		constraint UX_SchemaChange_SchemaChangeObject unique (ServerName, DatabaseName, ObjectName)
	);

if OBJECT_ID('[SchemaChange].[SchemaChangeEvent]') is null
	create table [SchemaChange].[SchemaChangeEvent] (
		SchemaChangeEventID int not null identity
			constraint PK_SchemaChange_SchemaChange primary key,
		TriggerEventType int not null,
		PostTime datetime2(2) not null, -- local
		SchemaChangeUserID int not null
			constraint FK_SchemaChange_SchemaChangeUserID
			references [SchemaChange].[SchemaChangeUser] (SchemaChangeUserID),
		SchemaChangeObjectID int not null
			constraint FK_SchemaChange_SchemaChangeObjectID
			references [SchemaChange].[SchemaChangeObject] (SchemaChangeObjectID),
		AlterTableActionList xml not null,
		CommandText nvarchar(MAX)
	);
go

-- ----------------------------------------------------------------------------
-- Called by the [SchemaChange].[v_SchemaValidation] view.
--		SELECT TOP 5 * FROM [SchemaChange].[v_SchemaChange] ORDER BY 1 DESC
create or alter view [SchemaChange].[v_SchemaChange] as
	SELECT
		e.SchemaChangeEventID,
		e.PostTime,
		u.LoginName,
		u.UserName,
		tet.[type_name] as TriggerEventTypeName,
		o.DatabaseName,
		o.ObjectName,
		e.CommandText,
		e.AlterTableActionList
	FROM [SchemaChange].[SchemaChangeEvent] e
	join sys.trigger_event_types tet on e.TriggerEventType = tet.[type]
	join [SchemaChange].[SchemaChangeUser] u on e.SchemaChangeUserID = u.SchemaChangeUserID
	join [SchemaChange].[SchemaChangeObject] o on e.SchemaChangeObjectID = o.SchemaChangeObjectID;
go

-- ----------------------------------------------------------------------------
create or ALTER proc [SchemaChange].[p_StatusReport] as
	select top 0 db_id() as database_id, * into #triggers from sys.triggers;

	insert into #triggers exec sp_msforeachdb N'use ?; select db_id(), * from sys.triggers;';

	select top 0 db_id() as database_id, * into #procedures from sys.procedures;

	insert into #procedures exec sp_msforeachdb N'use ?; select db_id(), * from sys.procedures;';

	declare @StorageCount int = (
		select count(*)
		from #procedures
		where name = 'p_SaveSchemaChange'
			and OBJECT_SCHEMA_NAME(object_id, database_id) = 'SchemaChange'
	);

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
			end as Stores,
		iif(v.name is null, '', 'Yes') as [Validation]
	from sys.databases d
	left join #triggers t 
		on t.database_id = d.database_id 
		and t.name = 't_SchemaChange'
		and t.parent_class_desc = 'DATABASE'
	left join #procedures s 
		on s.database_id = d.database_id 
		and s.name = 'p_SaveSchemaChange'
		and OBJECT_SCHEMA_NAME(s.object_id, s.database_id) = 'SchemaChange'
	left join #procedures v
		on v.database_id = d.database_id 
		and v.name = 'p_ValidateSchema'
		and OBJECT_SCHEMA_NAME(v.object_id, v.database_id) = 'SchemaValidation'
	where d.owner_sid <> 0x01
	order by d.name;
go

-- ----------------------------------------------------------------------------
-- This proc gets called by a database trigger in other databases.
-- Those triggers are fired by schema changes.
-- This proc does 2 things:
-- 1 - Records the schema change event.
-- 2 - Run the validation proc if it exists.
create or alter proc [SchemaChange].[p_SaveSchemaChange] 
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

	insert [SchemaChange].[SchemaChangeUser] (LoginName, UserName)
	select @LoginName, @UserName
	except
	select LoginName, UserName 
	from [SchemaChange].[SchemaChangeUser] WITH (HOLDLOCK, UPDLOCK); 
	-- HOLDLOCK and UPDLOCK prevent deadlocks when using INSERT EXCEPT.

	insert [SchemaChange].[SchemaChangeObject] (ServerName, DatabaseName, ObjectName)
	select @@SERVERNAME, @DatabaseName, @ObjectName
	except
	select ServerName, DatabaseName, ObjectName
	from [SchemaChange].[SchemaChangeObject] WITH (HOLDLOCK, UPDLOCK);

	insert [SchemaChange].[SchemaChangeEvent] (
		TriggerEventType,
		PostTime,
		SchemaChangeUserID,
		SchemaChangeObjectID,
		AlterTableActionList,
		CommandText
	)
	select
		t.[type] as TriggerEventType,
		@PostTime,
		u.SchemaChangeUserID,
		o.SchemaChangeObjectID,
		@AlterTableActionList,
		@CommandText
	from sys.trigger_event_types t
	cross join [SchemaChange].[SchemaChangeUser] u
	cross join [SchemaChange].[SchemaChangeObject] o
	where t.[type_name] = @TriggerEventTypeName
		and u.LoginName = @LoginName 
		and u.UserName = @UserName
		and o.ServerName = @@SERVERNAME
		and o.DatabaseName = @DatabaseName
		and o.ObjectName = @ObjectName;

	return SCOPE_IDENTITY();
go

if exists (select * from sys.triggers where name = 't_SchemaChange' and parent_class_desc = 'DATABASE')
	enable trigger [t_SchemaChange] on database;
go


