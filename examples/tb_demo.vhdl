-- tb_demo.vhdl
--
-- VHDL twin of examples/tb_demo.v / .sv for the GHDL and NVC flows. Two
-- unconnected component kinds funnelled to one viewer over one socket:
--   * interactive_ctrl "btn_run"   -- viewer-driven gate for a counter.
--   * interactive_flag "led_count" -- the 8-bit counter.
--   * interactive_flag "led_hb"    -- a heartbeat blinker.

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity tb_demo is
end entity;

architecture sim of tb_demo is
    signal clk    : std_logic := '0';
    signal enable : std_logic_vector(0 downto 0);
    signal count  : std_logic_vector(7 downto 0) := (others => '0');
    signal hb     : std_logic_vector(0 downto 0) := "0";
begin
    clk <= not clk after 5 ns;       -- 100 MHz

    u_btn : entity work.interactive_ctrl
        generic map (NAME => "btn_run", WIDTH => 1, POLL_US => 1000)
        port map (value => enable);

    process(clk)
    begin
        if rising_edge(clk) then
            if enable(0) = '1' then
                count <= std_logic_vector(unsigned(count) + 1);
            end if;
        end if;
    end process;

    u_led : entity work.interactive_flag
        generic map (NAME => "led_count", WIDTH => 8)
        port map (value => count);

    process
    begin
        wait for 200 us;
        hb(0) <= not hb(0);          -- heartbeat, independent of everything
    end process;

    u_hb : entity work.interactive_flag
        generic map (NAME => "led_hb", WIDTH => 1)
        port map (value => hb);
end architecture;
