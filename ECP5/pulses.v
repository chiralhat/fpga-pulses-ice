module pulses(
	      /* This module sets up the output logic, including the pulse and block switches, the attenuator(s),
	       and the scope trigger. It needs to have two modes:

	       A CW mode, which holds both switches open, and outputs a trigger for the scope and the SynthHD.
	       This mode is chosen by setting the 'mode' input to 0.
	       Inputs are 'period', 'pre_att', and 'post_att'.

	       A pulsed mode, which opens the pulse switch to chop the pulses up, closes the block switch for
	       only the period after each pi pulse where we expect the echo to be (if blocking is on).
	       This mode is chosen by setting the 'mode' input to a nonzero value, denoting the number of pi pulses.
	       If 'mode' is 1, a Hahn echo is taken, otherwise it's CPMG. 
	       Inputs are 'pum
	       */
	      input 	   clk, //The 50 MHz clock
	      input 	   clk_pll, // The 200 MHz clock
	      input 	   reset, // Used only in simulation
	      input [31:0] per, //Period
	      input [15:0] p1wid, //Width of pulse 1
	      input [15:0] del, //Delay between pulses
	      input [15:0] p2wid, //Width of pulse 2/cpmg pulses
	      input [15:0] p1wid2,
	      input [15:0] del2,
	      input [15:0] p2wid2,
	      input [15:0] p1st2,
	      input [7:0]  nut_w, //Width of nutation pulse
	      input [15:0] nut_d, //Nutation pulse delay - ends this many cycles before new period starts
	      input [6:0]  pr_att,
	      input [6:0]  po_att,
	      input [7:0]  cp, //CPMG settting: 0 for CW, 1 for Hahn echo, N>1 for CPMG with N pulses
	      input [7:0]  p_bl, //start of block open after pulses
	      input [15:0] p_bl_hf, //half of pulse_block
	      input 	   bl,
	      input 	   phsub, 
	      input 	   rxd,
	      output 	   sync_on, // Wire for scope trigger pulse
	      output 	   pulse1_on, // Wire for switch pulse
	      output 	   pulse2_on, 
	      output [6:0] pre_att, // Wires for main attenuator
	      output [6:0] post_att, // Wires for second attenuator
	      output 	   pre_block,
	      output 	   phase90,
	      output 	   phase180,
	      output 	   inhib // Wire for blocking switch pulse
	      );

   reg [31:0] 		   counter = 32'd0; // 32-bit for times up to 21 seconds
   reg 			   sync;
   reg 			   pulse; //overall output - is 1 if pulses or nut_pulse is 1
   reg 			   pulses; //pulse register
   reg 			   pulse2;
   reg 			   pulse2s;
   reg 			   nut_pulse; //nutation pulse register
   reg [6:0] 		   pre_att_val;
   reg [6:0] 		   post_att_val;
   reg 			   pr_inh;
   reg 			   inh;
   reg 			   rec = 0;
   reg 			   cw = 0;
   reg 			   ph90;
   reg 			   ph180;
   reg [1:0] 		   pcounter = 2'd0;
   
   // Running at a 201-MHz clock, our time step is ~5 (4.975) ns.
   // All the times are thus divided by 4.975 ns to get cycles.
   // 32-bit allows times up to 21 seconds
   
   reg [31:0] 		   period = 10000;
   reg [15:0] 		   p1width;
   reg [15:0] 		   delay;
   reg [15:0] 		   p2width;
   reg [15:0] 		   p1width2;
   reg [15:0] 		   p2width2;
   reg [15:0] 		   p1start2;
   reg [15:0] 		   p2start2;
   reg [15:0] 		   p2stop2;
   reg [7:0] 		   pulse_block;
   reg [15:0] 		   pulse_block_half;
   reg [7:0] 		   cpmg;
   reg 			   block;
   reg 			   phase_sub; 			   
   reg 			   rx_done;
   
   reg [15:0] 		   p2start;
   reg [15:0] 		   sdown;
   reg [15:0] 		   sync_down;
   reg [15:0] 		   block_off;
   reg [15:0] 		   block_on;

   reg [7:0] 		   nutation_pulse_width;
   reg [15:0] 		   nutation_pulse_delay;
   reg [23:0] 		   nutation_pulse_start;
   reg [23:0] 		   nutation_pulse_stop;

   reg [7:0] 		   ccount = 0; // Which pi pulse are we on right now
   reg [31:0] 		   cdelay = 1000; // What is the time of the next pi pulse beginning
   reg [31:0] 		   cpulse; // What is the time of the next pi pulse ending
   reg [31:0] 		   cblock_delay; // When to stop blocking before the next return signal
   reg [31:0] 		   cblock_on; // When to start blocking after the next return signal

   reg [1:0] 		   xfer_bits = 1;
   
   assign sync_on = sync; // The scope trigger pulse
   assign pulse1_on = pulse; // The switch pulse
   assign pulse2_on = pulse2; // The switch pulse
   assign pre_att = pre_att_val; // The main attenuator control
   assign post_att = post_att_val; // The second attenuator control
   assign pre_block = pr_inh; // The input blocking pulse (to completely squelch leakage)
   assign inhib = inh; // The blocking switch pulse
   assign phase90 = ph90; // The 90 degree phase shifter
   assign phase180 = ph180; // The 180 degree phase shifter

   
   //In order to improve timing on clk_pll, do everything possible on slower clk block
   //Since clk is 50 MHz and clk_pll is 200 MHz (even multiple), hopefully should reduce problems with two blocks being out of sync
   always @(posedge clk) begin
      period  <= per;
      p1width <= p1wid;
      p2width <= p2wid;
      p2width2 <= p2wid2;
      p1start2 <= p1st2;
      delay <= del;
      nutation_pulse_delay <= nut_d;
      nutation_pulse_width <= nut_w;
      pulse_block <= p_bl;
      pulse_block_half <= p_bl_hf;
      cpmg <= cp;
      block <= bl;
      phase_sub <= phsub;
      
      //Calculate these values here, since they only change when their components are updated - better for timing
      p2start <= p1width + delay;
      p1width2 <= p1wid2 + p1start2;
      p2start2 <= p1start2 + p1width2 + del2;
      p2stop2 <= p2start2 + p2width2;
      sdown <= p2start + p2width;// + 10;
      block_off <= sdown + pulse_block;
      block_on <= period - 10;
      nutation_pulse_start <= per - nutation_pulse_delay - nutation_pulse_width;
      nutation_pulse_stop <= per - nutation_pulse_delay;
      
      //Improves clk_pll timing, though not implemented exactly the same as in HX8K code due to presence of CPMG logic changing things
      cw <= (cpmg > 0) ? 0 : 1;
      
   end
   
   /* The main loops runs on the 200 MHz PLL clock.
    */
   always @(posedge clk_pll) begin
	 //Calculate nutation pulse and regular pulses separately, then combine them later, to improve timing
	 //If nutation pulse is not needed, can just set its width to 0
	 case (cpmg)
	   0 : begin //cpmg=0 : CW (switch always open)
	      pulse <= !block;
	      pulse2 <= block;
	      sync <= (counter < sdown) ? 0 : 1;
	      inh <= 0;
	      pr_inh <= 1;
	      pre_att_val <= pr_att;
	      
	   end
	   default : begin //cpmg > 1 : CPMG with # pulses given by value of cpmg
 	      sync <= (counter < sync_down) ? 1 : 0; //Leave sync on until sync_down (end of pulses)

	      pulses <= (counter < p1width) ? 1 :// Switch pulse goes up before p1width
			((counter < cdelay) ? 0 : //Then down (if cw mode not on) before p2start
			 ((counter < cpulse) ? (((ccount < cpmg) && (p2width > 0)) ? 1 : 0) : 0));
	      
 	      inh <= (counter < cblock_delay) ? block :
		     ((counter < cblock_on) ? ((ccount < cpmg) ? 0 : inh) :
 		      ((counter < (nutation_pulse_start-5)) ? inh : block));
	      
 	      nut_pulse <= (counter < nutation_pulse_start) ? 0 :
			   ((counter < nutation_pulse_stop) ? 1 : 0);

	      pulse2s <= (counter < p1start2) ? 0 :
      			 ((counter < p1width2) ? 1 :
      			  ((counter < p2start2) ? 0 :
      			   ((counter < p2stop2) ? 1 : 0)));

	      pre_att_val <= (counter < p1width | (counter > p1start2 && counter < p1width2)) ? pr_att+6 :
				 ((counter < (period-20)) ? pr_att : pr_att+6);

	      ph90 <= phsub ? ((counter < cdelay) ? 0 : 1) : 0;
	      ph180 <= phsub ? ((counter < cdelay) ? ^pcounter : pcounter[1]) : 0;
	      

	      case (counter) //case blocks generally seem to be faster than if-else, from what I've seen
		0: begin //at 0, turn on sync, pulses, and block, then calculate initial values of time markers
		   sync_down <= sdown;

		   cdelay <= p1width + delay; //start of first CPMG pulse after initial pulse
		   cpulse <= sdown; //end of first CPMG pulse
		   cblock_delay <= sdown + pulse_block; //start of first block open 
		   cblock_on <= sdown + 2*delay-5; //end of first block open
		   ccount <= 0;
		   pcounter <= pcounter + 1;
		end // case: 0

		cpulse: begin		 
		   if (ccount < cpmg) begin //if we have not yet reached the last pulse, set pulses to 0 and recalculate time marker values
		      cdelay <= cpulse + delay + delay; //start of next pulse = current place + 2*delay
		      cpulse <= cpulse + delay + delay + p2width; //end of next pulse = current place + 2*delay + width of next pulse
		      sync_down <= cpulse;
		      
		   end
		   // else begin
		   //    sync <= 0;
		   //    end
		   
		end //case: cpulse

		cblock_on: begin
		   if (ccount < (cpmg-1)) begin //if we have not reached the last pulse, close block and recalculate block marker values
		      
		      cblock_delay <= cpulse + pulse_block; //start of next open period = end of next pulse + block delay
		      cblock_on <= cpulse + 2*delay-5; //end of next open period = end of next pulse + block off
		      
		   end
		   ccount <= ccount + 1;
		end //case: cblock_on
		
	      endcase // case (counter)
	      pulse <= pulses;// | nut_pulse;
	      pulse2 <= pulse2s | nut_pulse;
	      pr_inh <= pulse | pulse2;
	   end
	 endcase
	 counter <= (counter < period) ? counter + 1 : 0; // Increment the counter until it reaches the period   

   end // always @ (posedge clk_pll)
endmodule // pulses
