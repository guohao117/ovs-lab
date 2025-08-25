#!/bin/bash
# Show OpenFlow rules in a more readable format

echo "=== OpenFlow ARP Proxy + MAC Forwarding Rules ==="
echo ""

echo "🎯 ARP Proxy Rules (Priority 200):"
ovs-ofctl dump-flows br-lab | grep "priority=200" | while read line; do
    if [[ $line =~ arp_tpa=([0-9.]+) ]]; then
        ip="${BASH_REMATCH[1]}"
        packets=$(echo "$line" | grep -o "n_packets=[0-9]*" | cut -d= -f2)
        echo "  • ARP proxy for $ip: $packets packets processed"
    fi
done

echo ""
echo "📦 MAC Forwarding Rules (Priority 100):"
ovs-ofctl dump-flows br-lab | grep "priority=100" | while read line; do
    if [[ $line =~ dl_dst=([0-9a-f:]+) ]]; then
        mac="${BASH_REMATCH[1]}"
        packets=$(echo "$line" | grep -o "n_packets=[0-9]*" | cut -d= -f2)
        case $mac in
            "02:00:00:00:01:01") container="c1 (10.0.0.1)" ;;
            "02:00:00:00:01:02") container="c2 (10.0.0.2)" ;;
            "02:00:00:00:01:03") container="c3 (10.0.0.3)" ;;
            *) container="unknown" ;;
        esac
        echo "  • Forward to $container: $packets packets"
    fi
done

echo ""
echo "🌊 Default Rules:"
ovs-ofctl dump-flows br-lab | grep -E "(priority=150|priority=50)" | while read line; do
    if [[ $line =~ priority=150 ]]; then
        packets=$(echo "$line" | grep -o "n_packets=[0-9]*" | cut -d= -f2)
        echo "  • Drop unknown ARP requests: $packets packets dropped"
    elif [[ $line =~ priority=50 ]]; then
        packets=$(echo "$line" | grep -o "n_packets=[0-9]*" | cut -d= -f2)
        echo "  • Flood unknown destinations: $packets packets flooded"
    fi
done

echo ""
echo "📊 Quick Test Commands:"
echo "  ./lab.sh exec c1 ping -c 2 10.0.0.2    # Test c1→c2"
echo "  ./lab.sh exec c2 ping -c 2 10.0.0.3    # Test c2→c3"
echo "  ./lab.sh exec c1 arp -a                 # Show ARP table"
echo "  ./show-flows.sh                         # Show this summary"
