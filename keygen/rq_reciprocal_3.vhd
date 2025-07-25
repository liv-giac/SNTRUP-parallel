library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use ieee.math_real.all;

use work.constants.all;
use work.data_type.all;

-- Calculates the inversion of a short polynomial multiplied by 3 in Rq:
-- out = 1 / (3*f). Output is ordered highest degree first
entity rq_reciprocal_3 is
	port(
		clock               : in  std_logic;
		reset               : in  std_logic;
		start               : in  std_logic;
		small_polynomial_in : in  std_logic_vector(1 downto 0);
		ready               : out std_logic;
		output_polynomial   : out std_logic_vector(q_num_bits - 1 downto 0);
		output_valid        : out std_logic;
		done                : out std_logic
	);
end entity rq_reciprocal_3;

architecture RTL of rq_reciprocal_3 is

	constant loop_limit : integer := 2 * p - 1;
	constant b : integer := 4;
	constant bram_address_width : integer := integer(ceil(log2(real((p + 1)/(b+1)))));
	type address_vector is array (0 to b) of std_logic_vector(bram_address_width - 1 downto 0);
	type data_vector is array (0 to b) of std_logic_vector(q_num_bits - 1 downto 0);
	type freeze_vector is array (0 to b) of signed(q_num_bits - 1 downto 0);
	function modq_reciprocal(a : integer)
	return integer is
		variable ai : integer := a;
	begin
		for i in 1 to q - 3 loop
			
			--report "ai= " & integer'image(ai) & " i=" & integer'image(i);
			ai := ai * a;
			while ai >= integer(ceil(real(q) / real(2))) loop
				ai := ai - q;
			end loop;
			while ai <= -integer(ceil(real(q) / real(2))) loop
				ai := ai + q;
			end loop;
		end loop;
		return ai;
	end function modq_reciprocal;

	-- Reciprocal of 3 mod q
	constant reciproc_3 : integer := modq_reciprocal(3);

	signal counter             : integer range 0 to loop_limit + 1 := 0;
	type state_type is (init_state, reset_ram, ready_state, running_state, swap_state_1, swap_state_2, swap_state_3, multiply_state_read, multiply_final_state_1, multiply_final_state_2, multiply_final_state_3, calc_reciprocal_init, calc_reciprocal_init_2, calc_reciprocal, output_data, done_state);
	signal state_rq_reciprocal : state_type;

	signal counter_vr : integer range 0 to p + 2;
	signal counter_fg : integer range 0 to p + 2;

	signal small_polynomial_in_delay : std_logic_vector(1 downto 0);

	signal bram_f_data_in_a : data_vector;
	signal bram_g_data_in_a : data_vector;
	signal bram_v_data_in_a : data_vector;
	signal bram_r_data_in_a : data_vector;

	signal bram_f_write_a : std_logic_vector(b downto 0);
	signal bram_g_write_a : std_logic_vector(b downto 0);
	signal bram_v_write_a : std_logic_vector(b downto 0);
	signal bram_r_write_a : std_logic_vector(b downto 0);

	signal bram_f_address_a : address_vector;
	signal bram_g_address_a : address_vector;
	signal bram_v_address_a : address_vector;
	signal bram_r_address_a : address_vector;

	signal bram_f_data_out_a : data_vector;
	signal bram_g_data_out_a : data_vector;
	signal bram_v_data_out_a : data_vector;
	signal bram_r_data_out_a : data_vector;

	signal swap_mask_s : std_logic;

	signal f_zero : std_logic_vector(q_num_bits - 1 downto 0);
	signal g_zero : std_logic_vector(q_num_bits - 1 downto 0);

	signal fg_freeze : freeze_vector;

	signal bram_g_data_in_b : data_vector;

	constant pipeline_length : integer := 5;

	type address_delay is array (pipeline_length downto 0) of address_vector;
	type write_delay is array (pipeline_length downto 0) of std_logic_vector (b downto 0);


	signal bram_g_address_b_delay : address_delay;
	signal bram_g_write_b_delay   : write_delay;

	signal vr_freeze : freeze_vector;
	signal bram_r_address_b_delay : address_delay;
	signal bram_r_write_b_delay   : write_delay;

	-- Shift data in v RAM
	signal bram_shift_v_address_b : address_vector;
	signal bram_shift_v_data_in_b : data_vector;
	signal bram_shift_v_write_b   : std_logic_vector(b downto 0);

	signal reciprocal_start  : std_logic;
	signal reciprocal_input  : std_logic_vector(q_num_bits - 1 downto 0);
	signal reciprocal_ready  : std_logic;
	signal reciprocal_done   : std_logic;
	signal reciprocal_output : std_logic_vector(q_num_bits - 1 downto 0);

	signal output_pre_freeze : signed(q_num_bits * 2 - 1 downto 0);
	signal output_freeze     : signed(q_num_bits - 1 downto 0);

	signal output_valid_pipe : std_logic_vector(pipeline_length downto 0);

begin

	main : process(clock, reset) is
		variable delta : signed(15 downto 0);
		variable extra : integer;
		variable swap_mask : signed(15 downto 0);

	begin
		if reset = '1' then
			state_rq_reciprocal <= init_state;

			reciprocal_start <= '0';
			reciprocal_input <= (others => '0');

			bram_g_address_b_delay(0) <= (others => (others => '0'));
			bram_g_write_b_delay(0)   <=(others => '0');

			bram_r_address_b_delay(0) <= (others => (others => '0'));
			bram_r_write_b_delay(0)   <= (others => '0');

			bram_f_write_a <= (others => '0');
			bram_g_write_a <= (others => '0');
			bram_v_write_a <= (others => '0');
			bram_r_write_a <= (others => '0');

			bram_f_data_in_a <= (others => (others => '0'));
			bram_g_data_in_a <= (others => (others => '0'));
			bram_v_data_in_a <= (others => (others => '0'));
			bram_r_data_in_a <= (others => (others => '0'));

			f_zero <= (others => '0');
			g_zero <= (others => '0');

			bram_shift_v_write_b    <= (others => '0');
			bram_r_write_b_delay(0) <= (others => '0');

			done <= '0';
			ready <= '0';

			output_valid_pipe(0) <= '0';
		elsif rising_edge(clock) then
			case state_rq_reciprocal is
				when init_state =>
					state_rq_reciprocal  <= ready_state;
					delta                := to_signed(1, 16);
					swap_mask            := (others => '0');
					counter              <= 0;
					counter_vr           <= 0;
					counter_fg           <= 0;
					output_valid_pipe(0) <= '0';
					ready                <= '0';
					swap_mask_s          <= '0';
					done                 <= '0';
				when ready_state =>
					if start = '1' then
						
						state_rq_reciprocal <= reset_ram;
						ready               <= '0';
					else
						state_rq_reciprocal <= ready_state;
						ready               <= '1';
					end if;
					bram_f_write_a <= (others => '0');
					bram_g_write_a <= (others => '0');
					bram_v_write_a <= (others => '0');
					bram_r_write_a <= (others => '0');
				when reset_ram => ---still saves one coefficient at a time but in banked logic
				---added a reset since this time it's not the same bram being written to every iteration, but every b + 1 times
					
					bram_f_write_a <= (others => '0');
					bram_g_write_a <= (others => '0');
					bram_v_write_a <= (others => '0');
					bram_r_write_a <= (others => '0');

					bram_f_address_a(counter_fg mod (b+1)) <= std_logic_vector(to_unsigned(integer(counter_fg/(b+1)), bram_address_width));
					bram_g_address_a((p - 1 - counter_fg) mod (b+1)) <= std_logic_vector(to_signed(integer((p - 1 - counter_fg)/ (b+1)), bram_address_width + 1)(bram_address_width - 1 downto 0));

					bram_v_address_a(counter_vr mod (b+1)) <= std_logic_vector(to_unsigned(integer(counter_vr/(b+1)), bram_address_width));
					bram_r_address_a(counter_vr mod (b+1)) <= std_logic_vector(to_unsigned(integer(counter_vr/(b+1)), bram_address_width));

					if counter_fg = 0 then
						bram_f_data_in_a(counter_fg mod (b+1))  <= std_logic_vector(to_signed(1, q_num_bits));
					elsif counter_fg = p or counter_fg = p - 1 then
						bram_f_data_in_a(counter_fg mod (b+1))  <= std_logic_vector(to_signed(-1, q_num_bits));
					else
						bram_f_data_in_a(counter_fg mod (b+1))  <= (others => '0');
					end if;

					if counter_fg < p then
						bram_g_data_in_a((p - 1 - counter_fg) mod (b+1)) <= std_logic_vector(resize(signed(small_polynomial_in_delay), q_num_bits));
					else
						bram_g_data_in_a(p mod (b+1)) <= (others => '0');
						bram_g_address_a(p mod (b+1)) <= std_logic_vector(to_unsigned(integer(p/(b+1)), bram_address_width));
					end if;

					bram_v_data_in_a(counter_vr mod (b+1)) <= (others => '0');

					if counter_vr = 0 then
						bram_r_data_in_a(counter_vr mod (b+1)) <= std_logic_vector(to_signed(reciproc_3, q_num_bits));
					else
						bram_r_data_in_a(counter_vr mod (b+1)) <= (others => '0');
					end if;

					bram_f_write_a(counter_fg mod (b+1)) <= '1';
					if counter_fg = p then
					bram_g_write_a((p) mod (b+1)) <= '1';
						else
					bram_g_write_a((p - 1 - counter_fg) mod (b+1)) <= '1';
					end if;
					bram_v_write_a(counter_vr mod (b+1)) <= '1';
					bram_r_write_a(counter_vr mod (b+1)) <= '1';

					counter_fg <= counter_fg + 1;
					counter_vr <= counter_vr + 1;
					if counter_fg < p + 1 then
						state_rq_reciprocal <= reset_ram;

					else
						state_rq_reciprocal <= running_state;
					end if;

				when running_state =>
					if counter >= loop_limit then
						state_rq_reciprocal <= calc_reciprocal_init;
					else
						state_rq_reciprocal <= swap_state_1;
					end if;
					bram_g_address_a <= (others => (others => '0'));
					bram_f_address_a <= (others => (others => '0'));

					counter                 <= counter + 1;
					counter_fg              <= 1;
					counter_vr              <= 0;
					bram_g_write_b_delay(0) <= (others => '0');
					bram_r_write_b_delay(0) <= (others => '0');
					bram_shift_v_write_b    <= (others => '0');
					bram_f_write_a          <= (others => '0');
					bram_g_write_a          <= (others => '0');
					bram_v_write_a          <= (others => '0');
					bram_r_write_a          <= (others => '0');
					extra:=0;
				when swap_state_1 =>
					state_rq_reciprocal <= swap_state_2;
				when swap_state_2 =>
					state_rq_reciprocal <= swap_state_3;
					---it's always the first value of g so in the first bank
					swap_mask           := negative_mask(-delta) AND non_zero_mask(signed(bram_g_data_out_a(0)));
					delta               := (delta XOR (swap_mask AND (delta XOR -delta))) + to_signed(1, 16);

					if swap_mask(0) = '1' then
						swap_mask_s <= not swap_mask_s;
					else
						swap_mask_s <= swap_mask_s;
					end if;
				when swap_state_3 =>
					state_rq_reciprocal <= multiply_state_read;
					---it's always the first value of g and f so in the first bank
					f_zero              <= bram_f_data_out_a(0);
					g_zero              <= bram_g_data_out_a(0);
				when multiply_state_read =>
				-- calculation to deal with the last iteration if the batching has a "remainder"
					if counter_fg + (b+1) > p + 1 then
							extra := (p+1) mod (b+1);				
						else
							extra := b + 1;
						end if;
					for i in 0 to extra - 1 loop
					bram_f_address_a((counter_fg+i) mod (b+1)) <= std_logic_vector(to_unsigned(integer((counter_fg+i)/ (b+1)), bram_address_width));
					bram_g_address_a((counter_fg+i) mod (b+1)) <= std_logic_vector(to_unsigned(integer((counter_fg+i)/ (b+1)), bram_address_width));
					bram_v_address_a((counter_vr+i) mod (b+1)) <= std_logic_vector(to_unsigned(integer((counter_vr+i)/ (b+1)), bram_address_width));
					bram_r_address_a((counter_vr+i) mod (b+1)) <= std_logic_vector(to_unsigned(integer((counter_vr+i)/ (b+1)), bram_address_width));

					bram_g_address_b_delay(0)((counter_fg+i) mod (b+1))<= std_logic_vector(to_unsigned(integer((counter_fg+i)/ (b+1)), bram_address_width));
					bram_g_write_b_delay(0)((counter_fg+i) mod (b+1))   <= '1';

					bram_r_address_b_delay(0)((counter_vr+i)mod (b+1))  <= std_logic_vector(to_unsigned(integer((counter_vr+i)/ (b+1)), bram_address_width));
					bram_r_write_b_delay(0)((counter_vr+i)mod (b+1))    <= '1';
					end loop;
					counter_fg <= counter_fg + extra;
					counter_vr <= counter_vr + extra;
					if counter_fg + extra >= p + 1  then
						state_rq_reciprocal <= multiply_final_state_1;
					else
						state_rq_reciprocal <= multiply_state_read;
					end if;

					-- Shift data in v RAM in all loops except last
					--shifting logic on batched ram needs to take into account that for b out of b+1 elements the address doesn't change, only the bram index changes,
					--instead for the final one the address changes because we have wraparound
					if counter = loop_limit then
						bram_shift_v_write_b <= (others => '0');
					else
						bram_shift_v_write_b <= (others => '0');
						if counter_vr = extra then
							bram_shift_v_address_b(0) <= (others => '0');
							bram_shift_v_data_in_b(0) <= (others => '0');
							bram_shift_v_write_b(0)   <= '1';
						else
							if counter_vr > extra then
								for i in 0 to extra-1 loop
								bram_shift_v_address_b((i+1)mod (b+1)) <= std_logic_vector(to_unsigned(integer((counter_vr+i)/(b+1))-2, bram_address_width));
								bram_shift_v_data_in_b((i+1)mod (b+1)) <= bram_v_data_out_a(i);
								bram_shift_v_write_b((i+1)mod (b+1))   <= '1';
								end loop;
								bram_shift_v_write_b(0)  <= '0';
									if extra = b+1 then
										bram_shift_v_data_in_b(0) <= bram_v_data_out_a(b);
										bram_shift_v_address_b(0) <= std_logic_vector(to_unsigned(integer((counter_vr+b)/(b+1))-1, bram_address_width));
										bram_shift_v_write_b(0)  <= '1';
									end if;
							end if;
						end if;
					end if;

				when multiply_final_state_1 =>
					bram_g_write_b_delay(0) <= (others => '0');

					bram_r_write_b_delay(0) <= (others => '0');
					state_rq_reciprocal     <= multiply_final_state_2;
					bram_shift_v_write_b    <= (others => '0');

					bram_f_address_a <=  (others => (others => '0'));
					bram_g_address_a <= (others => (others => '0'));
				when multiply_final_state_2 =>
					state_rq_reciprocal     <= multiply_final_state_3;
					bram_shift_v_write_b    <= (others => '0');
					bram_g_write_b_delay(0) <= (others => '0');

					bram_v_address_a <=  (others => (others => '0'));
					bram_r_address_a <=  (others => (others => '0'));
				when multiply_final_state_3 =>
					state_rq_reciprocal     <= running_state;
					bram_shift_v_write_b    <= (others => '0');
					bram_g_write_b_delay(0) <= (others => '0');

					bram_v_address_a <= (others => (others => '0'));
					bram_r_address_a <= (others => (others => '0'));
				when calc_reciprocal_init =>
					state_rq_reciprocal <= calc_reciprocal_init_2;
					bram_f_address_a    <= (others => (others => '0'));
				when calc_reciprocal_init_2 =>
					state_rq_reciprocal <= calc_reciprocal;
				when calc_reciprocal =>
					reciprocal_start <= '1';
					reciprocal_input <= bram_f_data_out_a(0);
					counter_vr       <= 0;
					if reciprocal_done = '1' then
						state_rq_reciprocal <= output_data;
						reciprocal_start    <= '0';
					else
						state_rq_reciprocal <= calc_reciprocal;
					end if;
				when output_data =>
				-- outputs one coefficient at a time moving across brams
					
					bram_v_address_a((p -  1 -counter_vr) mod (b+1))    <= std_logic_vector(to_signed(integer((p -  1 -counter_vr) / (b+1)), bram_address_width + 1)(bram_address_width - 1 downto 0));
					counter_vr           <= counter_vr + 1;
					output_valid_pipe(0) <= '1';
					if counter_vr < p then
						state_rq_reciprocal <= output_data;
					else
						state_rq_reciprocal  <= done_state;
						output_valid_pipe(0) <= '0';
					end if;
				when done_state =>

					state_rq_reciprocal  <= init_state;
					output_valid_pipe(0) <= '0';
					done                 <= '1';
			end case;
		end if;
	end process main;
					
	modq_reciprocal_inst : entity work.modq_reciprocal
		port map(
			clock  => clock,
			reset  => reset,
			start  => reciprocal_start,
			input  => reciprocal_input,
			ready  => reciprocal_ready,
			done   => reciprocal_done,
			output => reciprocal_output
		);
						--makes sure to get the right bram index out
	output_pre_freeze <= signed(reciprocal_output) * signed(bram_v_data_out_a((p -  1 -counter_vr) mod (b+1))) when rising_edge(clock);

	modq_freeze_inst_scale : entity work.modq_freeze(RTL)
		port map(
			clock  => clock,
			reset  => reset,
			input  => output_pre_freeze,
			output => output_freeze
		);

	output_polynomial <= std_logic_vector(output_freeze);

	delay_output_valid : process(clock, reset) is
	begin
		if reset = '1' then
			--output_valid_pipe(pipeline_length downto 1) <= (others => '0');
		elsif rising_edge(clock) then
			output_valid_pipe(pipeline_length downto 1) <= output_valid_pipe(pipeline_length - 1 downto 0);
		end if;
	end process delay_output_valid;

	output_valid <= output_valid_pipe(pipeline_length-1);

	-- Multiplication of f0*g[i]-g0*f[i]
	minus_product_gen_fg : for i in 0 to b generate
	modq_minus_product_inst_fg : entity work.modq_minus_product
		port map(
			clock         => clock,
			reset         => reset,
			data_in_a     => bram_g_data_out_a(i),
			data_in_b     => bram_f_data_out_a(i),
			f_zero        => f_zero,
			g_zero        => g_zero,
			output_freeze => fg_freeze(i)
		);
	end generate;
	
	bram_gen : for i in 0 to b generate
	bram_g_data_in_b(i) <= std_logic_vector(fg_freeze(i)) when bram_g_address_b_delay(pipeline_length)(i) /= std_logic_vector(to_unsigned(integer(p/(b+1)), bram_address_width)) else (others => '0');
			end generate;
	-- Delay the write to g bram to wait for freeze pipeline to complete.
	-- Also shifts the address by one to implement the shift of g
	--shifting logic on batched ram needs to take into account that for b out of b+1 elements the address doesn't change, only the bram index changes,
			--instead for the first one the address changes because we have wraparound
	delay_bram_g_port_b : process(clock, reset) is
	begin
		if reset = '1' then
			--bram_g_address_b_delay(pipeline_length downto 1) <= (others => (others => '0'));
			--bram_g_write_b_delay(pipeline_length downto 1)   <= (others => '0');
		else

			if rising_edge(clock) then
				bram_g_address_b_delay(1)(b) <= std_logic_vector(signed(bram_g_address_b_delay(0)(0)) - to_signed(1, bram_address_width));

				bram_g_address_b_delay(pipeline_length downto 2) <= bram_g_address_b_delay(pipeline_length - 1 downto 1); -- & std_logic_vector(signed(bram_g_address_b_delay(0)) - to_signed(1, bram_address_width));

				if bram_g_address_b_delay(0)(0) = std_logic_vector(to_unsigned(0, bram_address_width)) then
					bram_g_write_b_delay(1)(b) <= '0';
				else
					bram_g_write_b_delay(1)(b) <= bram_g_write_b_delay(0)(0);
				end if;
				for i in 1 to b loop
					bram_g_address_b_delay(1)(i-1) <= bram_g_address_b_delay(0)(i);
					bram_g_write_b_delay(1)(i-1) <= bram_g_write_b_delay(0)(i);
				end loop;
				bram_g_write_b_delay(pipeline_length downto 2) <= bram_g_write_b_delay(pipeline_length - 1 downto 1);

			end if;
		end if;
	end process delay_bram_g_port_b;

	small_polynomial_in_delay <= small_polynomial_in when rising_edge(clock);

	-- Multiplication of f0*r[i]-g0*v[i]
	minus_product_gen_vr : for i in 0 to b generate
	modq_minus_product_inst_vr : entity work.modq_minus_product
		port map(
			clock         => clock,
			reset         => reset,
			data_in_a     => bram_r_data_out_a(i),
			data_in_b     => bram_v_data_out_a(i),
			f_zero        => f_zero,
			g_zero        => g_zero,
			output_freeze => vr_freeze(i)
		);
	end generate;

	delay_bram_r_port_b : process(clock, reset) is
	begin
		if reset = '1' then
			--bram_r_address_b_delay(pipeline_length downto 1) <= (others => (others => '0'));
			--bram_r_write_b_delay(pipeline_length downto 1)   <= (others => '0');
		else
			if rising_edge(clock) then
				bram_r_address_b_delay(pipeline_length downto 1) <= bram_r_address_b_delay(pipeline_length - 1 downto 0);
				bram_r_write_b_delay(pipeline_length downto 1)   <= bram_r_write_b_delay(pipeline_length - 1 downto 0);
			end if;
		end if;
	end process delay_bram_r_port_b;

	bram_rq_reciprocal_gen : for i in 0 to b generate
	bram_rq_reciprocal_3_inst : entity work.bram_rq_reciprocal_3
		generic map(
			bram_address_width => bram_address_width,
			bram_data_width    => q_num_bits
		)
		port map(
			clock             => clock,
			swap_mask_s       => swap_mask_s,
			bram_f_data_in_a  => bram_f_data_in_a(i),
			bram_g_data_in_a  => bram_g_data_in_a(i),
			bram_v_data_in_a  => bram_v_data_in_a(i),
			bram_r_data_in_a  => bram_r_data_in_a(i),
			bram_f_write_a    => bram_f_write_a(i),
			bram_g_write_a    => bram_g_write_a(i),
			bram_v_write_a    => bram_v_write_a(i),
			bram_r_write_a    => bram_r_write_a(i),
			bram_f_address_a  => bram_f_address_a(i),
			bram_g_address_a  => bram_g_address_a(i),
			bram_v_address_a  => bram_v_address_a(i),
			bram_r_address_a  => bram_r_address_a(i),
			bram_f_data_out_a => bram_f_data_out_a(i),
			bram_g_data_out_a => bram_g_data_out_a(i),
			bram_v_data_out_a => bram_v_data_out_a(i),
			bram_r_data_out_a => bram_r_data_out_a(i),
			bram_f_data_in_b  => (others => '0'),
			bram_g_data_in_b  => bram_g_data_in_b(i),
			bram_v_data_in_b  => bram_shift_v_data_in_b(i),
			bram_r_data_in_b  => std_logic_vector(vr_freeze(i)),
			bram_f_write_b    => '0',
			bram_g_write_b    => bram_g_write_b_delay(pipeline_length)(i),
			bram_v_write_b    => bram_shift_v_write_b(i),
			bram_r_write_b    => bram_r_write_b_delay(pipeline_length)(i),
			bram_f_address_b  => (others => '0'),
			bram_g_address_b  => bram_g_address_b_delay(pipeline_length)(i),
			bram_v_address_b  => bram_shift_v_address_b(i),
			bram_r_address_b  => bram_r_address_b_delay(pipeline_length)(i),
			bram_f_data_out_b => open,
			bram_g_data_out_b => open,
			bram_v_data_out_b => open,
			bram_r_data_out_b => open
		);
		end generate;

end architecture RTL;