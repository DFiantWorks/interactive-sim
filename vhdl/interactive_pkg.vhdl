-- interactive_pkg.vhdl
--
-- Foreign (VHPIDIRECT) bindings to the shared C++ backend
-- (../backend/interactive.cpp), plus small helpers.
--
-- GHDL/NVC bind each subprogram to the C symbol named in its `foreign` attribute.
-- Handles are passed as plain integers (ids into a registry on the C side)
-- because VHPIDIRECT marshals scalars (integer/real), not pointers.
--
-- The component NAME is passed as a BOUNDED string -- a constrained
-- string(1 to NAME_MAX) -- together with its real length. GHDL passes a
-- constrained array as a pointer to its first character (the C side reads
-- `namelen` chars from it); it does NOT implement marshaling an *unconstrained*
-- `string`, so the fixed-size subtype is what keeps the foreign call portable
-- across GHDL and NVC.

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

package interactive_pkg is

    constant NAME_MAX : natural := 255;
    subtype  name_t   is string(1 to NAME_MAX);

    function slv2int(v : std_logic_vector) return integer;

    -- Pad (or truncate) an arbitrary NAME into the fixed-size name_t buffer.
    function pad_name(s : string) return name_t;

    -- Open a viewer-driven control; returns an integer handle.
    procedure ctrl_open(handle : out integer; name : in name_t;
                        namelen : in integer; width : in integer);
    attribute foreign of ctrl_open : procedure is "VHPIDIRECT vhpi_ctrl_open";

    -- Latest viewer value for a control.
    procedure ctrl_read(handle : in integer; result : out integer);
    attribute foreign of ctrl_read : procedure is "VHPIDIRECT vhpi_ctrl_read";

    -- Open a design-driven flag; returns an integer handle.
    procedure flag_open(handle : out integer; name : in name_t;
                        namelen : in integer; width : in integer);
    attribute foreign of flag_open : procedure is "VHPIDIRECT vhpi_flag_open";

    -- Push a flag value (tagged with the current sim time, us) to the viewer.
    procedure flag_write(handle : in integer; t : in real; value : in integer);
    attribute foreign of flag_write : procedure is "VHPIDIRECT vhpi_flag_write";

    procedure comp_close(handle : in integer);
    attribute foreign of comp_close : procedure is "VHPIDIRECT vhpi_close";

end package;

package body interactive_pkg is

    function slv2int(v : std_logic_vector) return integer is
    begin
        return to_integer(unsigned(v));
    end function;

    function pad_name(s : string) return name_t is
        variable r : name_t := (others => character'val(0));
        variable n : integer := s'length;
    begin
        if n > NAME_MAX then
            n := NAME_MAX;
        end if;
        if n > 0 then
            r(1 to n) := s(s'low to s'low + n - 1);
        end if;
        return r;
    end function;

    -- Foreign bodies are never executed (GHDL/NVC call the C symbol instead) but
    -- must be present and legal.
    procedure ctrl_open(handle : out integer; name : in name_t;
                        namelen : in integer; width : in integer) is
    begin
        handle := 0;
    end procedure;

    procedure ctrl_read(handle : in integer; result : out integer) is
    begin
        result := 0;
    end procedure;

    procedure flag_open(handle : out integer; name : in name_t;
                        namelen : in integer; width : in integer) is
    begin
        handle := 0;
    end procedure;

    procedure flag_write(handle : in integer; t : in real; value : in integer) is
    begin
        null;
    end procedure;

    procedure comp_close(handle : in integer) is
    begin
        null;
    end procedure;

end package body;
