library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.mem_types.all;
use work.mem_components.all;

entity BusController is

  port (
    clk, rst                               : in    std_logic;
    busReq                                 : in    std_logic_vector(N_CACHES-1 downto 0);
    busAddr                                : in    std_logic_vector(WORD_ADDR_WIDTH-1 downto 0);
    busCmd                                 : in    bus_cmd_t;
    busData                                : inout data_block_t;
    busGrant                               : out   std_logic_vector(N_CACHES-1 downto 0);
    memCs, memRead, memWrite, memWriteWord : out   std_logic;
    memAddr                                : out   std_logic_vector(WORD_ADDR_WIDTH-1 downto 0);
    memWrData                              : out   data_block_t;
    memRdData                              : in    data_block_t;
    memDone                                : in    std_logic);

end entity BusController;

architecture rtl of BusController is
  type bus_state_t is (ST_IDLE, ST_GRANT, ST_WAIT_MEM);
  signal busSt, busStNext : bus_state_t := ST_IDLE;

  signal arbiterArbitrate : std_logic;
  signal arbiterReqValid  : std_logic;
  signal arbiterReqId     : std_logic_vector(CACHE_IDX_WIDTH-1 downto 0);
  
  -- Tri State Buffer
  signal busOutEn : std_logic;

begin  -- architecture rtl

  comb_proc : process () is
  begin  -- process comb_proc
    -- signals that need initialization here
    busStNext <= busSt;
    memDone <= '0';

	--Default values (internal flags):
	arbiterArbitrate<='0';
	
	--Default values (outputs):
	busGrant<='0';
	memCs<='0';

	-- tri state buffer (busOutEn<=0;)
	busData <= (others => 'Z'); 
	busOutEn <= '0';

	
    -- control: state machine
    case busSt is
      when ST_IDLE =>
	if arbiterReqValid = '1' then
	  busStNext <= ST_GRANT;
	end if;

      when ST_GRANT =>
	arbiterArbitrate <= '1';
	busGrant(to_integer(unsigned(arbiterReqId))) <= '1';
	memCs <= '1';
	
	busStNext <= ST_WAIT_MEM;

      when ST_WAIT_MEM =>
	if memDone = '1' then

		-- busOutEn <= '1'; (tri state buffer)
		busOutEn <= '1';
		busData <= memRdData;
		
		busStNext <= ST_IDLE;
	else
		busGrant(to_integer(unsigned(arbiterReqId))) <= '1';
	end if;

      when others => null;
    end case;

    -- datapath
  end process comb_proc;

  busArbiter_1 : busArbiter
    port map (
      clk              => clk,
      arbiterArbitrate => arbiterArbitrate,
      arbiterBusReqIn  => busReq,
      arbiterReqValid  => arbiterReqValid,
      arbiterReqId     => arbiterReqId);

  
  clk_proc : process (clk, rst) is
  begin  -- process clk_proc (combinatorial)
    if rst = '0' then                   -- asynchronous reset (active low)
      busSt <= ST_IDLE;
    elsif clk'event and clk = '1' then  -- rising clock edge
      busSt <= busStNext;
    end if;
  end process clk_proc;

-- cmdDecoder
cmdDecoder : process(busCmd) is 
begin
 	-- Default values (no command received)
	memRead <= '0';
	memWrite <= '0';
	memWriteWord <= '0';

	if busCmd = BUS_WRITE_WORD then
		memWriteWord <= '1';
	else if busCmd = BUS_WRITE then
		memWrite <= '1';
	else if busCmd = BUS_READ then
		memRead <= '1';
	end if;
  end process cmdDecoder;

-- others signals (direct in to out)
	memAddr <= busAddr;
	memWrData <= busData;


end architecture rtl;
