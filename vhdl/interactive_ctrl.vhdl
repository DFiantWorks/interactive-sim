-- interactive_ctrl.vhdl
--
-- VHDL viewer-driven INPUT for the shared interactive-sim backend, the twin of
-- sv/interactive_ctrl.sv. Droppable anywhere in the hierarchy, unconnected to
-- anything else.
--
--   interactive_ctrl -- NO clock; self-paces on its own POLL_US timer
--                       (wait for), so it is asynchronous to the rest of the
--                       design. `value` tracks the latest viewer value for NAME.
--
-- NAME (channel id + viewer label) must be unique across the simulation.

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use work.interactive_pkg.all;

entity interactive_ctrl is
    generic (
        NAME    : string  := "ctrl";
        WIDTH   : integer := 1;
        POLL_US : integer := 1000      -- self-paced sample period (us); 1 ms default
    );
    port (
        value : out std_logic_vector(WIDTH - 1 downto 0)
    );
end entity;

architecture rtl of interactive_ctrl is
    constant HEARTBEAT_US : integer := 1000;   -- internal heartbeat period (us)
begin
    -- No clock: poll the viewer's latest value on this instance's own timebase.
    process
        variable handle : integer := -1;
        variable v      : integer;
    begin
        ctrl_open(handle, pad_name(NAME), NAME'length, WIDTH);
        value <= (others => '0');
        loop
            wait for POLL_US * 1 us;
            ctrl_read(handle, v);
            value <= std_logic_vector(to_unsigned(v, WIDTH));
        end loop;
    end process;

    -- Heartbeat: only the first interactive component to start claims the single
    -- heartbeat slot and runs the periodic tick; every other instance stays idle.
    -- One timer, one message, regardless of how many components the design has.
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
