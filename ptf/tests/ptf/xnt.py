# Copyright 2013-2018 Barefoot Networks, Inc.
# SPDX-License-Identifier: LicenseRef-ONF-Member-Only-1.0 AND Apache-2.0

# eXtensible Network Telemetry

from scapy.fields import *
from scapy.packet import *


class INT_META_HDR(Packet):
    name = "INT_META"
    fields_desc = [BitField("ver", 0, 4),
                   BitField("rep", 0, 2),
                   BitField("c", 0, 1),
                   BitField("e", 0, 1),
                   BitField("rsvd1", 0, 3),
                   BitField("ins_cnt", 0, 5),
                   BitField("max_hop_cnt", 32, 8),
                   BitField("total_hop_cnt", 0, 8),
                   ShortField("inst_mask", 0),
                   ShortField("rsvd2", 0x0000)]


class INT_L45_HEAD(Packet):
    name = "INT_L45_HEAD"
    fields_desc = [XByteField("int_type", 0x01),
                   XByteField("rsvd0", 0x00),
                   XByteField("length", 0x00),
                   XByteField("rsvd1", 0x00)]


class INT_L45_TAIL(Packet):
    name = "INT_L45_TAIL"
    fields_desc = [XByteField("next_proto", 0x01),
                   XShortField("proto_param", 0x0000),
                   XByteField("rsvd", 0x00)]