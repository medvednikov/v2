module bench

import os

pub struct Step {
pub:
	name    string
	time_us i64
	ram_kb  i64
}

pub struct Bench {
mut:
	steps    []Step
	start_us i64
	t0_us    i64
}

pub fn new() Bench {
	now := bench_now_us()
	return Bench{
		start_us: now
		t0_us:    now
	}
}

pub fn (mut b Bench) step(name string) {
	now := bench_now_us()
	elapsed_us := now - b.t0_us
	ram_mb := f64(current_rss_kb()) / 1024.0
	ms := f64(elapsed_us) / 1000.0
	println('  ${name:-20s} ${ms:8.2f} ms   ${ram_mb:6.0f} MB resident RAM')
	b.steps << Step{
		name:    name
		time_us: elapsed_us
		ram_kb:  i64(ram_mb * 1024)
	}
	b.t0_us = now
}

pub fn (b &Bench) print_report() {
	total_us := bench_now_us() - b.start_us
	total_ms := f64(total_us) / 1000.0
	println('  ${'total':-20s} ${total_ms:8.2f} ms')
	println('')
}

fn bench_now_us() i64 {
	return C.clock()
}

fn current_rss_kb() i64 {
	$if macos {
		return macos_rss_kb()
	}
	$if linux {
		return linux_rss_kb()
	}
	return 0
}

fn macos_rss_kb() i64 {
	result := os.execute('ps -o rss= -p ${C.getpid()}')
	if result.exit_code == 0 {
		return result.output.trim_space().i64()
	}
	return 0
}

fn linux_rss_kb() i64 {
	content := os.read_file('/proc/self/status') or { return 0 }
	for line in content.split('\n') {
		if line.starts_with('VmRSS:') {
			parts := line.split_any(' \t').filter(it.len > 0)
			if parts.len >= 2 {
				return parts[1].i64()
			}
		}
	}
	return 0
}

fn C.getpid() int

fn C.clock() i64
