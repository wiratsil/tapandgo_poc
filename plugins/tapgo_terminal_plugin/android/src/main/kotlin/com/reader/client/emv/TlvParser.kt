package com.reader.client.emv

object TlvParser {
    fun parse(hex: String): List<Tlv> {
        val tlvs = mutableListOf<Tlv>()
        var index = 0
        while (index < hex.length) {
            var tagEnd = index + 2
            if (tagEnd > hex.length) {
                break
            }
            val tagByte1 = hex.substring(index, index + 2).toInt(16)
            if ((tagByte1 and 0x1F) == 0x1F) {
                do {
                    tagEnd += 2
                    if (tagEnd > hex.length) {
                        break
                    }
                    val nextByte = hex.substring(tagEnd - 2, tagEnd).toInt(16)
                    if ((nextByte and 0x80) == 0) {
                        break
                    }
                } while (tagEnd < hex.length)
            }
            if (tagEnd > hex.length) {
                break
            }
            val tag = hex.substring(index, tagEnd)
            index = tagEnd

            if (index + 2 > hex.length) {
                break
            }
            var len = hex.substring(index, index + 2).toInt(16)
            index += 2
            if ((len and 0x80) != 0) {
                val numBytes = len and 0x7F
                if (index + numBytes * 2 > hex.length) {
                    break
                }
                len = hex.substring(index, index + numBytes * 2).toInt(16)
                index += numBytes * 2
            }

            if (index + len * 2 > hex.length) {
                break
            }

            val value = hex.substring(index, index + len * 2)
            index += len * 2

            val children = if (isConstructed(tag)) parse(value) else emptyList()
            tlvs.add(Tlv(tag, len, value, children))
        }
        return tlvs
    }

    private fun isConstructed(tag: String): Boolean {
        if (tag.isEmpty()) {
            return false
        }
        val tagByte = tag.substring(0, 2).toInt(16)
        return (tagByte and 0x20) != 0
    }
}
