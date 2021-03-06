library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.mem_types.all;
use work.mem_components.all;

entity CacheController is

  port (
    clk, rst                       : in    std_logic;
    cacheCs, cacheRead, cacheWrite : in    std_logic;
    cacheAddr                      : in    std_logic_vector(WORD_ADDR_WIDTH-1 downto 0);
    cacheWrData                    : in    data_word_t;
    cacheDone                      : out   std_logic;
    cacheRdData                    : out   data_word_t;
    busReq                         : out   std_logic;
    busCmd                         : inout bus_cmd_t;
    busSnoopValid                  : in    std_logic;
    busGrant                       : in    std_logic;
    busAddr                        : inout std_logic_vector(WORD_ADDR_WIDTH-1 downto 0);
    busData                        : inout data_block_t);
end entity CacheController;

architecture rtl of CacheController is

  -- States support
  type cache_ctrl_state_t is (ST_IDLE, ST_RD_HIT_TEST, ST_RD_WAIT_BUS_GRANT,
                              ST_RD_WAIT_BUS_COMPLETE,
                              ST_WR_HIT_TEST, ST_WR_WAIT_BUS_GRANT, ST_WR_WAIT_BUS_COMPLETE);
  signal cacheStNext, cacheSt : cache_ctrl_state_t := ST_IDLE;

  type snoop_state_t is (ST_SNOOP_IDLE, ST_SNOOP_INVALIDATING);
  signal snoopStNext, snoopSt : snoop_state_t := ST_SNOOP_IDLE;
  
  -- cpu req reg
  type cpu_req_reg_t is record
    wasInvalidatedIn : std_logic; -- cpuReqRegWasInvalidatedIn
    addr : std_logic_vector(WORD_ADDR_WIDTH-1 downto 0);
    data : data_word_t;
  end record cpu_req_reg_t;

  signal cpuReqRegWrEn : std_logic;
  signal cpuReqReg     : cpu_req_reg_t;
  signal cpuReqRegWord : std_logic_vector(WORD_OFFSET_WIDTH-1 downto 0);
  signal cpuReqRegWillInvalidate : std_logic;

  -- Victim reg
  type victim_reg_t is record
    set   : std_logic_vector(SET_ADDR_WIDTH-1 downto 0);
  end record victim_reg_t;
  signal victimRegWrEn : std_logic;
  signal victimReg     : victim_reg_t;

  -- tag Array
  signal tagLookupEn, tagWrEn, tagInvEn                                    : std_logic;
  signal tagWrSet                                                          : std_logic_vector(SET_ADDR_WIDTH-1 downto 0);
  signal tagAddr, tagInvAddr                                               : std_logic_vector(WORD_ADDR_WIDTH-1 downto 0);
  signal tagHitEn                                                          : std_logic;
  signal tagHitSet, tagVictimSet                                           : std_logic_vector(SET_ADDR_WIDTH-1 downto 0);
  
  -- data array
  signal dataArrayWrEn, dataArrayWrWord                                    : std_logic;
  signal dataArrayWrSetIdx                                                 : std_logic_vector(SET_ADDR_WIDTH-1 downto 0);
  signal dataArrayAddr                                                     : std_logic_vector(WORD_ADDR_WIDTH-1 downto 0);
  signal dataArrayWrData                                                   : data_block_t;
  signal dataArrayRdData                                                   : data_set_t;

  -- bus tri state buffer
  signal busOutEn  : std_logic;
  signal busAddrIn : std_logic_vector(WORD_ADDR_WIDTH-1 downto 0);
  signal busCmdIn  : bus_cmd_t;
  signal busDataIn : data_block_t;

  -- other datapath signals
  signal currReqWillInvalidate : std_logic;
  signal busWillInvalidate : std_logic;

-- 
begin  -- architecture rtl

  comb_proc : process (busAddrIn, busCmdIn, busData, busDataIn, busGrant,
                       busOutEn, cacheAddr, cacheCs, cacheRead, cacheSt,
                       cacheWrite, cpuReqReg, cpuReqRegWord,
                       dataArrayRdData, tagHitEn, tagHitSet,
                       tagVictimSet, victimReg) is
  begin  -- process comb_proc
    -- signals that need initialization
    cacheStNext <= cacheSt;
    cacheDone   <= '0';
    cacheRdOutEn <= '0';

    cpuReqRegWrEn <= '0';
    victimRegWrEn <= '0';

    tagLookupEn <= '0';
    tagWrEn     <= '0';

    dataArrayWrEn   <= '0';
    dataArrayWrWord <= '0';

    busReq   <= '0';
    busOutEn <= '0';

    tagInvEn <= '0';
    tagWrSetDirty <= '0';

    currReqWillInvalidate <= '0';
    busWillInvalidate <= '0';

    -- signals with dont care initialization
    cacheRdData   <= (others => 'Z');
    dataArrayAddr <= cacheAddr;

    busCmdIn     <= BUS_READ;
    busAddrIn    <= cpuReqReg.addr;
    busDataIn(0) <= cpuReqReg.data;
    busDataIn(1) <= cpuReqReg.data;

    tagWrSet <= victimReg.set;
    tagAddr  <= cpuReqReg.addr;

    dataArrayWrData   <= busData;
    dataArrayAddr     <= cpuReqReg.addr;
    dataArrayWrSetIdx <= tagVictimSet;

    -- control: state machine
    case cacheSt is

      -----------------------------------------------------------------------
      -- Idle state (same for all)
      -----------------------------------------------------------------------
      when ST_IDLE => 
	if(cacheCs = '1') then

		cpuReqRegWrEn <= '1';
		dataArrayAddr <= cacheAddr;
		tagAddr <= cacheAddr;
		tagLookupEn <= '1';

		if(cacheWrite = '1') then
			cacheStNext <= ST_WR_HIT_TEST;
		elsif(cacheRead = '1') then
			cacheStNext <= ST_RD_HIT_TEST;
		end if;

	elsif(arbiterReqValid = '1') then
		cacheStNext <= ST_RD_HIT_TEST;
	end if;

      -----------------------------------------------------------------------
      -- Rdb state machine
      -----------------------------------------------------------------------
      when ST_RD_HIT_TEST =>
		if (tagHitEn = '1' and cpuReqRegWillInvalidate = '0') then
			cacheDone <= '1';
			cacheRdOutEn <= '1';
			cacheRdData <= dataArrayRdData(to_integer(unsigned(tagHitSet)))(to_integer(unsigned(cpuReqRegAddr(0))));
			
			cacheStNext <= ST_IDLE;
		else
			victimRegWrEn <= '1';
			
			cacheStNext <= ST_WR_WAIT_BUS_GRANT;
		end if;

      when ST_RD_WAIT_BUS_GRANT =>
		if (busGrant = '1') then
			busReq <= '1';
			busOutEn <= '1';
			busCmd <= BUS_READ;
			busAddrIn <= cpuReqRegAddr;
			
			cacheStNext <= ST_WR_WAIT_BUS_COMPLETE;
		else
			busReq <= '1';
		end if;

      when ST_RD_WAIT_BUS_COMPLETE =>
		if (busGrant = '0') then
			cacheDone <= '1';
			cacheRdOutEn <= '1';
			cacheRdDataIn <= busDataWord;
			tagWrEn <= '1';
			tagWrSet <= victimRegSet;
			tagAddr <= cpuReqRegAddr;
			dataArrayWrEn <= '1';
			dataArrayWrSetIdx <= victimRegSet;
			dataArrayWrWord <= '0';
			dataArrayData <= busData;

			cacheStNext <= ST_IDLE;
		end if;

      -----------------------------------------------------------------------
      -- wr state machine
      -----------------------------------------------------------------------
      when ST_WR_HIT_TEST =>
	if(tagHitEn = '1' && cpuReqRegWillInvalidate = '0') then
		dataArrayWrEn<='1';
		dataArrayWrWord<='1';
		dataArrayWrSetIdx<=tagHitSet;
		dataArrayWrData<= x"0000" & cpuReqRegData;
	end if;
	cacheStNext <= ST_WR_WAIT_BUS_GRANT;
        
      when ST_WR_WAIT_BUS_GRANT =>
	busReq<='1';
	if(busGrant = '1') then
		busOutEn <= '1';
		busCmd <= BUS_WRITE;
		busAddrIn <= cpuRegReqAddr;
		busDataIn <= cpuReqRegData;
		cacheStNext <= ST_WR_WAIT_BUS_COMPLETE;
	end if;

      when ST_WR_WAIT_BUS_COMPLETE =>
	if(busGrant = '0') then
		cacheDone <= '1';
		cacheStNext <= ST_IDLE;
	end if;

      when others => null;
    end case;

    -----------------------------------------------------------------------
    -- snoop state machine
    -----------------------------------------------------------------------
    snoopStNext <= snoopSt;
    tagInvEn    <= '0';
    case snoopSt is

      when ST_SNOOP_IDLE =>
	if(busWillInvalidate = '1') then
		tagInvEn <= '1';
		snoopStNext <= ST_SNOOP_INVALIDATING;
	end if;

      when ST_SNOOP_INVALIDATING =>
	snoopStNext <= ST_SNOOP_IDLE;

      when others => null;
    end case;

    -- datapath:
  if busOutEn = '1' then
      busCmd  <= busCmdIn;
      busAddr <= busAddrIn;
      busData <= busDataIn;
    else
      busCmd  <= (others => 'Z');
      busAddr <= (others => 'Z');
      busData <= DATA_BLOCK_HIGH_IMPEDANCE;
    end if;

    cpuReqRegWord <= std_logic_vector(to_unsigned(getWordOffset(cpuReqReg.addr), cpuReqRegWord'length));

  end process comb_proc;

  
  busWillInvalidate <= '1' when ((busCmd = BUS_WRITE) and busSnoopValid and not(busGrant)
  
  currReqWillInvalidate <= '1' when ((cacheAddr = busAddr) and busWillInvalidate)
  
  cpuReqRegWillInvalidate <= '1' when (((cpuReqRegAddr = busAddr) and busWillInvalidate) or cpuReqRegWasInvalidated)
  
  
  TagArray_1 : TagArray
    port map (
      clk          => clk,
      rst          => rst,
      tagLookupEn  => tagLookupEn,
      tagWrEn      => tagWrEn,
      tagInvEn     => tagInvEn,
      tagWrSet     => tagWrSet,
      tagAddr      => tagAddr,
      tagInvAddr   => busAddr,
      tagHitEn     => tagHitEn,
      tagHitSet    => tagHitSet,
      tagVictimSet => tagVictimSet);

  DataArray_1 : DataArray
    port map (
      clk               => clk,
      dataArrayWrEn     => dataArrayWrEn,
      dataArrayWrWord   => dataArrayWrWord,
      dataArrayWrSetIdx => dataArrayWrSetIdx,
      dataArrayAddr     => dataArrayAddr,
      dataArrayWrData   => dataArrayWrData,
      dataArrayRdData   => dataArrayRdData);

  clk_proc : process (clk, rst) is
  begin  -- process clk_proc
    if rst = '0' then                   -- asynchronous reset (active low)
      cacheSt <= ST_IDLE;
    elsif clk'event and clk = '1' then  -- rising clock edge
      cacheSt <= cacheStNext;
      snoopSt <= snoopStNext;

      -- other regs go here
      if cpuReqRegWrEn = '1' then
        cpuReqReg.addr <= cacheAddr;
        cpuReqReg.data <= cacheWrData;
      end if;

      if victimRegWrEn = '1' then
        victimReg.set   <= tagVictimSet;
        victimReg.dirty <= tagVictimDirty;
        victimReg.addr  <= tagVictimAddr;
        victimReg.data  <= dataArrayRdData(to_integer(unsigned(tagVictimSet)));
      end if;

    end if;
  end process clk_proc;

end architecture rtl;
