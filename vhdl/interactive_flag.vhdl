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
    constant HEARTBEAT_US : integer := 1000;   -- internal heartbeat period (us)
begin
    process(value)
        variable handle : integer := -1;
    begin
        if handle = -1 then
            flag_open(handle, pad_name(NAME), NAME'length, WIDTH);
        end if;
        -- sim time in us (ns precision preserved as a fractional part)
        flag_write(handle, real(now / 1 ns) / 1000.0, slv2int(value));
    end process;

    -- Heartbeat: only the first interactive component to start claims the single
    -- heartbeat slot and runs the periodic tick; every other instance stays idle.
    -- This keeps the viewer learning sim time even while `value` is quiet, with one
    -- timer and one message regardless of how many components the design has.
    heartbeat : process
        variable owner : integer;
    begin
        claim_heartbeat(owner);
        if owner /= 0 then
            loop
                wait for HEARTBEAT_US * 1 us;
                tick(real(now / 1 ns) / 1000.0);
            end loop;
        else
            wait;
        end if;
    end process;
end architecture;
