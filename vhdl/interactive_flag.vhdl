-- interactive_flag.vhdl
--
-- VHDL design-driven OUTPUT for the shared interactive-sim backend, the twin of
-- sv/interactive_flag.sv. Droppable anywhere in the hierarchy, unconnected to
-- anything else.
--
--   interactive_flag -- pushes `value` to the viewer on every change
--                       (LED / 7-seg / status word).
--
-- NAME (channel id + viewer label) must be unique across the simulation.

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use work.interactive_pkg.all;

entity interactive_flag is
    generic (
        NAME  : string  := "flag";
        WIDTH : integer := 1
    );
    port (
        value : in std_logic_vector(WIDTH - 1 downto 0)
    );
end entity;

architecture rtl of interactive_flag is
begin
    process(value)
        variable handle : integer := -1;
    begin
        if handle = -1 then
            flag_open(handle, NAME, NAME'length, WIDTH);
        end if;
        -- sim time in us (ns precision preserved as a fractional part)
        flag_write(handle, real(now / 1 ns) / 1000.0, slv2int(value));
    end process;
end architecture;
