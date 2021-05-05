// Copyright 2021-present Open Networking Foundation
// SPDX-License-Identifier: LicenseRef-ONF-Member-Only-1.0

#ifndef __INT_MIRROR_PARSER__
#define __INT_MIRROR_PARSER__

// Parser of mirrored packets that will become INT reports. To simplify handling
// of reports at the collector, we remove all headers between Ethernet and IPv4
// (the inner one if processing a GTP-U encapped packet). We support generating
// reports only for IPv4 packets, i.e., cannot report IPv6 traffic.
parser IntReportMirrorParser (packet_in packet,
    /* Fabric.p4 */
    out egress_headers_t hdr,
    out fabric_egress_metadata_t fabric_md,
    /* TNA */
    out egress_intrinsic_metadata_t eg_intr_md) {

    state start {
        packet.extract(fabric_md.int_mirror_md);
        fabric_md.bridged.bmd_type = fabric_md.int_mirror_md.bmd_type;
        fabric_md.bridged.base.vlan_id = DEFAULT_VLAN_ID;
        fabric_md.bridged.base.mpls_label = 0; // do not push an MPLS label
#ifdef WITH_SPGW
        fabric_md.bridged.spgw.skip_spgw = true; // skip spgw encap
#endif // WITH_SPGW
        // Initialize report headers here to allocate constant fields on the
        // T-PHV (and save on PHV resources).
        /** report_ethernet **/
        hdr.report_ethernet.setValid();
        // hdr.report_ethernet.dst_addr = update later
        // hdr.report_ethernet.src_addr = update later

        /** report_eth_type **/
        hdr.report_eth_type.setValid();
        // hdr.report_eth_type.value = update later

        /** report_mpls (set valid later) **/
        // hdr.report_mpls.label = update later
        hdr.report_mpls.tc = 0;
        hdr.report_mpls.bos = 0;
        hdr.report_mpls.ttl = DEFAULT_MPLS_TTL;

        /** report_ipv4 **/
        hdr.report_ipv4.setValid();
        hdr.report_ipv4.version = 4w4;
        hdr.report_ipv4.ihl = 4w5;
        hdr.report_ipv4.dscp = INT_DSCP;
        hdr.report_ipv4.ecn = 2w0;
        // hdr.report_ipv4.total_len = update later
        // hdr.report_ipv4.identification = update later
        hdr.report_ipv4.flags = 0;
        hdr.report_ipv4.frag_offset = 0;
        hdr.report_ipv4.ttl = DEFAULT_IPV4_TTL;
        hdr.report_ipv4.protocol = PROTO_UDP;
        // hdr.report_ipv4.hdr_checksum = update later
        // hdr.report_ipv4.src_addr = update later
        // hdr.report_ipv4.dst_addr = update later

        /** report_udp **/
        hdr.report_udp.setValid();
        hdr.report_udp.sport = 0;
        // hdr.report_udp.dport = update later
        // hdr.report_udp.len = update later
        // hdr.report_udp.checksum = update never!

        /** report_fixed_header **/
        hdr.report_fixed_header.setValid();
        hdr.report_fixed_header.ver = 0;
        hdr.report_fixed_header.nproto = NPROTO_TELEMETRY_SWITCH_LOCAL_HEADER;
        // hdr.report_fixed_header.d = update later
        // hdr.report_fixed_header.q = update later
        // hdr.report_fixed_header.f = update later
        hdr.report_fixed_header.rsvd = 0;
        // hdr.report_fixed_header.hw_id = update later
        // hdr.report_fixed_header.seq_no = update later
        hdr.report_fixed_header.ig_tstamp = fabric_md.int_mirror_md.ig_tstamp;

        /** common_report_header **/
        hdr.common_report_header.setValid();
        // hdr.common_report_header.switch_id = update later
        hdr.common_report_header.ig_port = fabric_md.int_mirror_md.ig_port;
        hdr.common_report_header.eg_port = fabric_md.int_mirror_md.eg_port;
        hdr.common_report_header.queue_id = fabric_md.int_mirror_md.queue_id;

        /** local/drop_report_header (set valid later) **/
        hdr.local_report_header.queue_occupancy = fabric_md.int_mirror_md.queue_occupancy;
        hdr.local_report_header.eg_tstamp = fabric_md.int_mirror_md.eg_tstamp;
        hdr.drop_report_header.drop_reason = fabric_md.int_mirror_md.drop_reason;

        transition check_ethernet;
    }

    state check_ethernet {
        fake_ethernet_t tmp = packet.lookahead<fake_ethernet_t>();
        transition select(tmp.ether_type) {
            ETHERTYPE_CPU_LOOPBACK_INGRESS: set_cpu_loopback_ingress;
            ETHERTYPE_CPU_LOOPBACK_EGRESS: set_cpu_loopback_ingress;
            default: parse_eth_hdr;
        }
    }

    state set_cpu_loopback_ingress {
        hdr.fake_ethernet.setValid();
        // We will generate the INT report, which will be re-circulated back to the Ingress pipe.
        // We need to set it back to ETHERTYPE_CPU_LOOPBACK_INGRESS to enable processing
        // the INT report in the Ingress pipe as a standard INT report, instead of punting it to CPU.
        hdr.fake_ethernet.ether_type = ETHERTYPE_CPU_LOOPBACK_INGRESS;
        packet.advance(ETH_HDR_BYTES * 8);
        transition parse_eth_hdr;
    }

    state parse_eth_hdr {
        packet.extract(hdr.ethernet);
        transition select(packet.lookahead<bit<16>>()) {
#ifdef WITH_DOUBLE_VLAN_TERMINATION
            ETHERTYPE_QINQ: strip_vlan;
#endif // WITH_DOUBLE_VLAN_TERMINATION
            ETHERTYPE_VLAN &&& 0xEFFF: strip_vlan;
            default: check_eth_type;
        }
    }

    state strip_vlan {
        packet.advance(VLAN_HDR_BYTES * 8);
        transition select(packet.lookahead<bit<16>>()) {
// TODO: support stripping double VLAN tag
#if defined(WITH_XCONNECT) || defined(WITH_DOUBLE_VLAN_TERMINATION)
            ETHERTYPE_VLAN: reject;
#endif // WITH_XCONNECT || WITH_DOUBLE_VLAN_TERMINATION
            default: check_eth_type;
        }
    }

    state check_eth_type {
        packet.extract(hdr.eth_type);
#ifdef WITH_SPGW
        transition select(hdr.eth_type.value, fabric_md.int_mirror_md.strip_gtpu) {
            (ETHERTYPE_MPLS, _): strip_mpls;
            (ETHERTYPE_IPV4, 0): handle_ipv4;
            (ETHERTYPE_IPV4, 1): strip_ipv4_udp_gtpu;
            default: reject;
        }
#else
        transition select(hdr.eth_type.value) {
            ETHERTYPE_MPLS: strip_mpls;
            ETHERTYPE_IPV4: handle_ipv4;
            default: reject;
        }
#endif // WITH_SPGW
    }

    // We expect MPLS to be present only for mirrored packets (ingress-to-egress
    // or egress-to-egress). We will fix the ethertype in the INT control block.
    state strip_mpls {
        packet.advance(MPLS_HDR_BYTES * 8);
        bit<IP_VER_BITS> ip_ver = packet.lookahead<bit<IP_VER_BITS>>();
#ifdef WITH_SPGW
        transition select(fabric_md.int_mirror_md.strip_gtpu, ip_ver) {
            (1, IP_VERSION_4): strip_ipv4_udp_gtpu;
            (0, IP_VERSION_4): handle_ipv4;
            default: reject;
        }
#else
        transition select(ip_ver) {
            IP_VERSION_4: handle_ipv4;
            default: reject;
        }
#endif // WITH_SPGW
    }

#ifdef WITH_SPGW
    state strip_ipv4_udp_gtpu {
        packet.advance((IPV4_HDR_BYTES + UDP_HDR_BYTES + GTP_HDR_BYTES) * 8);
        transition handle_ipv4;
    }
#endif // WITH_SPGW

    state handle_ipv4 {
        // Extract only the length, required later to compute the lenght of the
        // report encap headers.
        ipv4_t ipv4 = packet.lookahead<ipv4_t>();
        fabric_md.int_ipv4_len = ipv4.total_len;
        transition accept;
    }
}

#endif // __INT_MIRROR_PARSER__
