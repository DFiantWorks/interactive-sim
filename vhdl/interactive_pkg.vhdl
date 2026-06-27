-- interactive_pkg.vhdl
--
-- Foreign (VHPIDIRECT) bindings to the shared C++ backend
-- (../backend/interactive.cpp), plus small std_logic helpers.
--
-- GHDL/NVC bind each subprogram to the C symbol named in its `foreign` attribute.
-- Handles are passed as plain integers (ids into a registry on the C side)
-- because VHPIDIRECT marshals integers, not pointers.
--
-- The component NAME is passed as a `string` together with its length: GHDL and
-- NVC pass an `in string` as a pointer to its first character, so the C side
-- reads `namelen` characters from that pointer (see vhdl/interactive_vhpi.cpp).

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

package interactive_pkg is

    function slv2int(v : std_logic_vector) return integer;

    -- Open a viewer-driven control; returns an integer handle.
    procedure ctrl_open(handle : out integer; name : in string;
                        namelen : in integer; width : in integer);
    attribute foreign of ctrl_open : procedure is "VHPIDIRECT vhpi_ctrl_open";

    -- Latest viewer value for a control.
    procedure ctrl_read(handle : in integer; result : out integer);
    attribute foreign of ctrl_read : procedure is "VHPIDIRECT vhpi_ctrl_read";

    -- Open a design-driven flag; returns an integer handle.
    procedure flag_open(handle : out integer; name : in string;
                        namelen : in integer; width : in integer);
    attribute foreign of flag_open : procedure is "VHPIDIRECT vhpi_flag_open";

    -- Push a flag value (tagged with the current sim time, ns) to the viewer.
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

    -- Foreign bodies are never executed (GHDL/NVC call the C symbol instead) but
    -- must be present and legal.
    procedure ctrl_open(handle : out integer; name : in string;
                        namelen : in integer; width : in integer) is
    begin
        handle := 0;
    end procedure;

    procedure ctrl_read(handle : in integer; result : out integer) is
    begin
        result := 0;
    end procedure;

    procedure flag_open(handle : out integer; name : in string;
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
