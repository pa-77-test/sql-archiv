-- [2026-11-14 23:08:17] последняя версия
USE [dwh2]
GO
/****** Объект:  StoredProcedure [finAnalytics].[loadPA_addCommBank]    Дата создания скрипта: 02.10.2026 17:56:06 ******/ 
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO


CREATE PROCEDURE [finAnalytics].[loadPA_addCommBank] 
		@repmonth date
AS
BEGIN
	
	--declare @repmonth date='2026-04-01'

	declare @sp_name NVARCHAR(255) = OBJECT_NAME(@@PROCID)
	declare @subjectHeader  nvarchar(250) ='ПА. Процедура обновления комиссий банков', @subject nvarchar(250)
	declare @msgHeader nvarchar(max)=concat('Внесение данных в таблицу PA_commPS: ',FORMAT(@repmonth, 'MMMM yyyy', 'ru-RU' ),char(10))
	declare @msgFloor nvarchar(max) =concat(char(10),'Отработала процедура: ',@sp_name)
	declare @message nvarchar(max)=''

	--старт лог
       declare @log_IsError bit=0
       declare @log_Mem nvarchar(2000)	='Ok'
       declare @mainPrc nvarchar(255)=''
      if (select OBJECT_ID( N'tempdb..#mainPrc')) is not null
                          set @mainPrc=(select top(1) sp_name from #mainPrc)
      exec finAnalytics.sys_log @sp_name,0, @mainPrc
	
	
	if (select count(*) from dwh2.finAnalytics.comm_Ecompay_tkb where repmonth=@repmonth)!=0
		or (select count(*) from dwh2.finAnalytics.comm_Ecompay_sngb where repmonth=@repmonth)!=0
	  begin
		begin try
  
		  begin tran  				
	
			--declare @repmonth date='2026-04-01'
			--собираем данные по Золотой Короне и размещаем в первичной таблице comm_korona
			delete dwh2.finAnalytics.comm_Korona where repmonth=@repmonth
			insert into dwh2.finAnalytics.comm_Korona (repmonth, date_time, pl_date, numDog, summ, payment_type_method_id, project_name, transaction_type, transaction_status,sumPay)
				select 
						repmonth=@repmonth
						,date_time=dateadd(year,-2000,a.ДатаСозданияДокумента)
						,pl_date=dateadd(month,1,datefromparts(year(dateadd(year,-2000,a.Дата)),month(a.Дата),1))
						,numDog=b.dogNum
						,summ=a.СуммаПолная
						,payment_type_method_id='korona'--указывать обязательно поле не должно быть пустым
						,project_name=''
						,transaction_type=''
						,transaction_status=''
						,sumPay=a.СуммаПолная
					from 
						(select
							repmonth=cast(dateadd(year,-2000,Дата) as date)
							,*
						 from stg._1cCMR.Документ_Платеж) a 
					left join dwh2.finAnalytics.PA_DOG b on a.Договор=b.dogGIUD_CMR
					left join stg._1cCMR.Справочник_ПлатежныеСистемы c on a.ПлатежнаяСистема=c.Ссылка
					where a.ПлатежнаяСистема=0xB8158548A1C7AF7B11EEF0D6F84CC139 --Золотая Корона
							and  datefromparts(year(a.repmonth),month(a.repmonth),1)=@repmonth
		
			--собираем данные по Т-Банк и размещаем в первичной таблице comm_Tbank
			 delete dwh2.finAnalytics.comm_Tbank where repmonth=@repmonth	
			 insert into dwh2.finAnalytics.comm_Tbank (repmonth, date_time, pl_date, numDog, summ, payment_type_method_id, project_name, transaction_type, transaction_status,sumPay)
				select
					repmonth=@repmonth
					,date_time=dateadd(year,-2000,a.Дата)
					--,pl_date=datefromparts(year(a.repmonth),month(a.repmonth),1)
					,pl_date=case
								when a.repmonth='2026-07-31' then '2026-08-01'
								when a.repmonth='2026-08-31' then '2026-09-01'
								else datefromparts(year(a.repmonth),month(a.repmonth),1)
								end
					,numDog=b.dogNum
					,summ=a.Сумма
					,payment_type_method_id='tb'--указывать обязательно поле не должно быть пустым
					,project_name=''
					,transaction_type=''
					,transaction_status=''
					,sumPay=a.Сумма
				 from (select repmonth=cast(dateadd(year,-2000,Дата) as date) ,* from stg._1cCMR.Документ_ВыдачаДенежныхСредств) a
				 left join dwh2.finAnalytics.PA_DOG b on a.Договор=b.dogGIUD_CMR
				 where a.ПлатежнаяСистема= 0xABBA6A05F3F880B741015F729CBA1DF1--Т-Банк
				 and a.Проведен=0x01 and a.ПометкаУдаления=0x00
				 and  datefromparts(year(a.repmonth),month(a.repmonth),1)=@repmonth
			-------------------------

			--подготавливаем справочник НДС
			drop table if exists #nds
			select
				dat1=dat
				,dat2=isnull(cast(dateadd(day,-1,lead(dat)over(order by dat))as date),'9999-01-01')
				,stavka=1+(nds/100)
			into #nds
			from dwh2.finAnalytics.spr_nds

			------------------
			drop table if exists #stavkaPS
			select
				dat1=dat
				,dat2=isnull(cast(dateadd(day,-1,lead(dat)over(partition by ps,lvl order by dat))as date),'9999-01-01')
				,stavka=stavka/100
				,dopParam
				,ps
				,method
			into #stavkaPS
			from dwh2.finAnalytics.SPR_stavkaPS



			drop table if exists #allPs
				create table #allPs(repmonth date,trn_date date, numdog varchar(20),summ float,ps varchar(20),method varchar(50))
				insert into #allPs(repmonth,trn_date,numdog,summ,ps,method)
					select 
						repmonth
						,trn_date=cast(date_time as date)						 
						,numdog
						,summ
						,ps='ecompay_tkb'
						,method=payment_type_method_id
					from dwh2.finAnalytics.comm_Ecompay_tkb
					where repmonth=@repmonth
					union all
					select 
						repmonth
						,trn_date=cast(date_time as date)						 
						,numdog
						,summ
						,ps='ecompay_sngb'
						,method=payment_type_method_id
					from dwh2.finAnalytics.comm_Ecompay_sngb
					where repmonth=@repmonth
					union all
					select 
						repmonth
						,trn_date=cast(date_time as date)						 
						,numDog
						,summ
						,ps='sbp'
						,method=payment_type_method_id
					from dwh2.finAnalytics.comm_sbp
					where repmonth=@repmonth
					union all
					select 
						repmonth
						,trn_date=cast(date_time as date)						 
						,numdog
						,summ
						,ps='sngb'
						,method=payment_type_method_id
					from dwh2.finAnalytics.comm_sngb
					where repmonth=@repmonth
					union all
					select 
						repmonth
						,trn_date=cast(date_time as date)						 
						,numdog
						,summ
						,ps='tkb'
						,method=payment_type_method_id
					from dwh2.finAnalytics.comm_tkb
					where repmonth=@repmonth
					union all
					select 
						repmonth
						,trn_date=cast(date_time as date)						 
						,numdog
						,summ
						,ps='vtkb'
						,method=payment_type_method_id
					from dwh2.finAnalytics.comm_vtkb
					where repmonth=@repmonth
					union all
					select 
						repmonth
						,trn_date=cast(date_time as date)						 
						,numdog
						,summ
						,ps='korona'
						,method=payment_type_method_id
					from dwh2.finAnalytics.comm_korona
					where repmonth=@repmonth
					union all
					select 
						repmonth
						,trn_date=cast(date_time as date)						 
						,numdog
						,summ
						,ps='psb'
						,method=payment_type_method_id
					from dwh2.finAnalytics.comm_psb
					where repmonth=@repmonth
					union all
					select 
						repmonth
						,trn_date=cast(date_time as date)						 
						,numdog
						,summ
						,ps='vsngb'
						,method=payment_type_method_id
					from dwh2.finAnalytics.comm_Vsngb
					where repmonth=@repmonth
					union all
					select 
						repmonth
						,trn_date=cast(date_time as date)
						,numdog
						,summ
						,ps='tb'
						,method=payment_type_method_id
					from dwh2.finAnalytics.comm_Tbank
					where repmonth=@repmonth
		

			drop table if exists #commPS
			create table #commPS (repmonth date, numdog varchar(20)
									,summ_Ecompay_tkb float
									,summ_Ecompay_sngb float
									,summ_Sbp float
									,summ_Sngb float
									,summ_Tkb float
									,summ_VTkb float
									,summ_Psb float
									,summ_Vsngb float
									,summ_Korona float
									,summ_Tbank float)
	
	

			insert into #commPS (repmonth, numdog ,summ_Ecompay_TKB,summ_Ecompay_SNGB,summ_Sbp,summ_Sngb,summ_Tkb,summ_VTkb
								,summ_Psb,summ_Vsngb ,summ_Korona,summ_Tbank)
			select
				repmonth
				,numdog
				 
				,summ_Ecompay_TKB=sum(l1.summ_Ecompay_TKB)
				,summ_Ecompay_SNGB=sum(l1.summ_Ecompay_SNGB)
				,summ_Sbp=sum(l1.summ_Sbp)
				,summ_Sngb=sum(l1.summ_Sngb)
				,summ_Tkb=sum(l1.summ_Tkb)
				,summ_VTkb=sum(l1.summ_VTkb)
				,summ_Psb=sum(l1.summ_Psb)
				,summ_Vsngb =sum(l1.summ_Vsngb) 
				,summ_Korona=sum(l1.summ_Korona)
				,summ_Tbank=sum(l1.summ_Tbank)
			from ( 
				select
					a.repmonth
					,a.numdog
					,summ_Ecompay_TKB=iif(a.ps='ecompay_tkb',a.summ/nds.stavka,0)
					,summ_Ecompay_SNGB=iif(a.ps='ecompay_sngb',a.summ/nds.stavka,0)
					,summ_Sbp=-1*iif(a.ps='sbp'
									,iif(a.summ/100*sps.stavka>=sps.dopParam
											,a.summ/100*sps.stavka
											,sps.dopParam)	
									,0)
					,summ_Sngb=-1*iif(a.ps='sngb'
										,iif(a.summ/100*sps.stavka>=sps.dopParam
											,a.summ/100*sps.stavka
											,sps.dopParam)	
							
										,0)
					,summ_Tkb=-1*iif(a.ps='tkb',a.summ,0)
					,summ_VTkb=-1*iif(a.ps='vtkb',a.summ,0)
					,summ_Psb=-1*iif(a.ps='psb',a.summ/100*sps.stavka,0)
					,summ_Vsngb=-1*nds.stavka*iif(a.ps='vsngb'
													,iif(a.summ/100*sngb.stavka>=sngb.dopParam
															,a.summ/100*sngb.stavka
															,sngb.dopParam)	
													,0)
					,summ_Korona=-1*iif(a.ps='korona',a.summ*sps.stavka,0)
					,summ_Tbank=-1*round(iif(a.ps='tb'
										,iif(a.summ*sps.stavka>=sps.dopParam
												,a.summ*sps.stavka
												,sps.dopParam)	
											,0)
										,2)
					,nds=isnull(nds.stavka,1)
					,stavka=isnull(sps.stavka,1)
					,dopParam=isnull(sps.dopParam,0)
				from #allPs a
				left join #nds nds on a.trn_date between nds.dat1 and nds.dat2
				left join (select * from #stavkaPS where ps!='vsngb') sps on a.repmonth between sps.dat1 and sps.dat2 and a.ps=sps.ps 
				left join (select * from #stavkaPS where ps='vsngb') sngb on a.repmonth between sngb.dat1 and sngb.dat2 and sngb.method like '%'+trim(a.method)+'%'
				)l1
	
			group by repmonth ,numdog



		--исключаем неопределенные договора по платежам  и подготавливаем сообщение
		drop table if exists #err
		select 
			* 
		into #err
		from #allPS where numdog is null
		delete #commPS where numdog is null

		delete dwh2.finAnalytics.PA_CommPS where repmonth=@repmonth
		 insert into dwh2.finAnalytics.PA_CommPs (repmonth, dogNum ,summ_Ecompay_TKB,summ_Ecompay_SNGB,summ_Sbp,summ_Sngb,summ_Tkb,summ_VTkb
												,summ_Psb,summ_Vsngb,summ_Korona,summ_Tbank)
			select
				repmonth
				,numDog
				,summ_Ecompay_TKB
				,summ_Ecompay_SNGB
				,summ_Sbp
				,summ_Sngb
				,summ_Tkb
				,summ_VTkb
				,summ_Psb
				,summ_Vsngb
				,summ_Korona
				,summ_Tbank
			from #commPS
-----------------------------------------------------------------------------------------------------------
-------------------------------------- БЛОК данных для таблицы PA_CommPS_Pl

		drop table if exists #allPs_Pl
		create table #allPs_PL(repmonth date,trn_date date, numdog varchar(20),summ float,ps varchar(20),method varchar(50),id int)
		insert into #allPs_Pl(repmonth,trn_date,numdog,summ,ps,method,id)
		select 
			repmonth=pl_date
			,trn_date=cast(date_time as date)
			,numdog
			,summ
			,ps='ecompay_tkb'
			,method=payment_type_method_id
			,id=1
		from dwh2.finAnalytics.comm_Ecompay_tkb
		where pl_date=@repmonth
		union all
		select 
			repmonth=pl_date
			,trn_date=cast(date_time as date)
			,numdog
			,summ
			,ps='ecompay_sngb'
			,method=payment_type_method_id
			,id=2
		from dwh2.finAnalytics.comm_Ecompay_sngb
		where pl_date=@repmonth
		union all
		select 
			repmonth=pl_date
			,trn_date=cast(date_time as date)
			,numDog
			,summ
			,ps='sbp'
			,method=payment_type_method_id
			,id=3
		from dwh2.finAnalytics.comm_sbp 
		where pl_date=@repmonth
		union all
		select 
			repmonth=pl_date
			,trn_date=cast(date_time as date)
			,numdog
			,summ
			,ps='sngb'
			,method=payment_type_method_id
			,id=4
		from dwh2.finAnalytics.comm_sngb
		where pl_date=@repmonth
		union all
		select 
			repmonth=pl_date
			,trn_date=cast(date_time as date)
			,numdog
			,summ
			,ps='tkb'
			,method=payment_type_method_id
			,id=5
		from dwh2.finAnalytics.comm_tkb
		where pl_date=@repmonth
		union all
		select 
			repmonth=pl_date
			,trn_date=cast(date_time as date)
			,numdog
			,summ
			,ps='psb'
			,method=payment_type_method_id
			,id=6
		from dwh2.finAnalytics.comm_Psb
		where pl_date=@repmonth
		union all
		select 
			repmonth=pl_date
			,trn_date=cast(date_time as date)
			,numdog
			,summ
			,ps='tb'
			,method=payment_type_method_id
			,id=7
		from dwh2.finAnalytics.comm_Tbank
		where pl_date=@repmonth
		union all
		select 
			repmonth=pl_date
			,trn_date=cast(date_time as date)
			,numdog
			,summ
			,ps='vsngb'
			,method=payment_type_method_id
			,id=8
		from dwh2.finAnalytics.comm_Vsngb
		where pl_date=@repmonth
		union all
		select 
			repmonth=pl_date
			,trn_date=cast(date_time as date)
			,numdog
			,summ
			,ps='vtkb'
			,method=payment_type_method_id
			,id=9	
		from dwh2.finAnalytics.comm_vtkb
		where pl_date=@repmonth
		union all
		select 
			repmonth=pl_date
			,trn_date=cast(date_time as date)
			,numdog
			,summ
			,ps='korona'
			,method=payment_type_method_id
			,id=10
		from dwh2.finAnalytics.comm_korona
		where pl_date=@repmonth
		
		drop table if exists #commPS_Pl
		create table #commPS_Pl (repmonth date, numdog varchar(20)
									,summ_Ecompay_tkb float
									,summ_Ecompay_sngb float
									,summ_Sbp float
									,summ_Sngb float
									,summ_Tkb float
									,summ_VTkb float
									,summ_Psb float
									,summ_Vsngb float
									,summ_Korona float
									,summ_Tbank float)
	
			insert into #commPS_Pl (repmonth, numdog ,summ_Ecompay_TKB,summ_Ecompay_SNGB,summ_Sbp,summ_Sngb,summ_Tkb,summ_VTkb
								,summ_Psb,summ_Vsngb ,summ_Korona,summ_Tbank)
			select
				repmonth
				,numdog
				 
				,summ_Ecompay_TKB=sum(l1.summ_Ecompay_TKB)
				,summ_Ecompay_SNGB=sum(l1.summ_Ecompay_SNGB)
				,summ_Sbp=sum(l1.summ_Sbp)
				,summ_Sngb=sum(l1.summ_Sngb)
				,summ_Tkb=sum(l1.summ_Tkb)
				,summ_VTkb=sum(l1.summ_VTkb)
				,summ_Psb=sum(l1.summ_Psb)
				,summ_Vsngb =sum(l1.summ_Vsngb) 
				,summ_Korona=sum(l1.summ_Korona)
				,summ_Tbank=sum(l1.summ_Tbank)
			from ( 
				select
					a.repmonth
					,a.numdog
					,summ_Ecompay_TKB=iif(a.ps='ecompay_tkb',a.summ/nds.stavka,0)
					,summ_Ecompay_SNGB=iif(a.ps='ecompay_sngb',a.summ/nds.stavka,0)
					,summ_Sbp=-1*iif(a.ps='sbp'
									,iif(a.summ/100*sps.stavka>=sps.dopParam
											,a.summ/100*sps.stavka
											,sps.dopParam)	
									,0)
					,summ_Sngb=-1*iif(a.ps='sngb'
										,iif(a.summ/100*sps.stavka>=sps.dopParam
											,a.summ/100*sps.stavka
											,sps.dopParam)	
							
										,0)
					,summ_Tkb=-1*iif(a.ps='tkb',a.summ,0)
					,summ_VTkb=-1*iif(a.ps='vtkb',a.summ,0)
					,summ_Psb=-1*iif(a.ps='psb',a.summ/100*sps.stavka,0)
					,summ_Vsngb=-1*nds.stavka*iif(a.ps='vsngb'
													,iif(a.summ/100*sngb.stavka>=sngb.dopParam
															,a.summ/100*sngb.stavka
															,sngb.dopParam)	
													,0)
					,summ_Korona=-1*iif(a.ps='korona',a.summ*sps.stavka,0)
					,summ_Tbank=-1*round(iif(a.ps='tb'
										,iif(a.summ*sps.stavka>=sps.dopParam
												,a.summ*sps.stavka
												,sps.dopParam)	
											,0)
										,2)
					,nds=isnull(nds.stavka,1)
					,stavka=isnull(sps.stavka,1)
					,dopParam=isnull(sps.dopParam,0)
				from #allPs_Pl a
				left join #nds nds on a.trn_date between nds.dat1 and nds.dat2
				left join (select * from #stavkaPS where ps!='vsngb') sps on a.repmonth between sps.dat1 and sps.dat2 and a.ps=sps.ps 
				left join (select * from #stavkaPS where ps='vsngb') sngb on a.repmonth between sngb.dat1 and sngb.dat2 and sngb.method like '%'+trim(a.method)+'%'
				)l1
	
			group by repmonth ,numdog
		
		delete #commPS_Pl where numdog is null

		delete dwh2.finAnalytics.PA_CommPS_Pl where repmonth=@repmonth
		 insert into dwh2.finAnalytics.PA_CommPS_Pl (repmonth, dogNum ,summ_Ecompay_TKB,summ_Ecompay_SNGB,summ_Sbp,summ_Sngb,summ_Tkb,summ_VTkb
												,summ_Psb,summ_Vsngb,summ_Korona,summ_Tbank)
			select
				repmonth
				,numDog
				,summ_Ecompay_TKB
				,summ_Ecompay_SNGB
				,summ_Sbp
				,summ_Sngb
				,summ_Tkb
				,summ_VTkb
				,summ_Psb
				,summ_Vsngb
				,summ_Korona
				,summ_Tbank
			from #commPS_Pl

-----------------------------------------------------------------------------------------------------------
		 commit tran
				if (select count(*) from #err)=0
					begin 
						set @subject=@subjectHeader 
						set @message=concat(@msgHeader,@msgFloor)
						exec finAnalytics.sendEmail @subject,@message ,@strRcp = '1'
					end
				else 
					begin
					set @subject = @subjectHeader
					set @message=N'<h3>Есть суммы по комиссиям не связанные с договорами:</h3>'
									+N'<table border=''1''>'
									+N'<tr><th>Отчетный месяц</th><th>Сумма</th><th>Платежная сиситема</th></tr>'
									+cast(
										(select
											td=repmonth,'' 
											,td=convert(varchar,format(summ,'N','ru-ru')),''
											,td=ps,''
										from #err for xml path('tr'), type) 
									as nvarchar(max))
									+N'</table>'
		
					set @message=@msgHeader+@message+N'<p>'+@msgFloor+N'</p>'
					exec finAnalytics.sendEmail @subject = @subject,@message =@message,@strRcp ='1',@f=1
					end
		
		--финиш
		exec dwh2.finAnalytics.sys_log  @sp_name,1, @mainPrc

		end try 
		 begin catch

			----кэтч

			set  @log_IsError =1
			set  @log_Mem =ERROR_MESSAGE()
			exec finAnalytics.sys_log  @sp_name,1, @mainPrc,  @log_IsError,  @log_Mem

			ROLLBACK TRANSACTION
			set @message=CONCAT('Ошибка выполнения процедуры - ',@sp_name,'. Ошибка ',ERROR_MESSAGE()) 
			set @subject='Ошибка! '
			set @message=concat(@msgHeader,@message)
			exec finAnalytics.sendEmail @subject ,@message ,@strRcp = '99'
		   ;throw 51000 
					,@message
					,1;    
		 end catch
	end
END