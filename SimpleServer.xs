/*
 * Copyright (c) 2000, Index Data.
 *
 * Permission to use, copy, modify, distribute, and sell this software and
 * its documentation, in whole or in part, for any purpose, is hereby granted,
 * provided that:
 *
 * 1. This copyright and permission notice appear in all copies of the
 * software and its documentation. Notices of copyright or attribution
 * which appear at the beginning of any file must remain unchanged.
 *
 * 2. The name of Index Data or the individual authors may not be used to
 * endorse or promote products derived from this software without specific
 * prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED "AS IS" AND WITHOUT WARRANTY OF ANY KIND,
 * EXPRESS, IMPLIED, OR OTHERWISE, INCLUDING WITHOUT LIMITATION, ANY
 * WARRANTY OF MERCHANTABILITY OR FITNESS FOR A PARTICULAR PURPOSE.
 * IN NO EVENT SHALL INDEX DATA BE LIABLE FOR ANY SPECIAL, INCIDENTAL,
 * INDIRECT OR CONSEQUENTIAL DAMAGES OF ANY KIND, OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER OR
 * NOT ADVISED OF THE POSSIBILITY OF DAMAGE, AND ON ANY THEORY OF
 * LIABILITY, ARISING OUT OF OR IN CONNECTION WITH THE USE OR PERFORMANCE
 * OF THIS SOFTWARE.
 */

/*$Log: SimpleServer.xs,v $
/*Revision 1.7  2001-03-13 14:17:15  sondberg
/*Added support for GRS-1.
/**/


#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"
#include <yaz/backend.h>
#include <yaz/log.h>
#include <yaz/wrbuf.h>
#include <stdio.h>
#include <unistd.h>
#include <stdlib.h>
#include <ctype.h>
#define GRS_MAX_FIELDS 50
#ifdef ASN_COMPILED
#include <yaz/ill.h>
#endif
#ifndef sv_undef		/* To fix the problem with Perl 5.6.0 */
#define sv_undef PL_sv_undef
#endif

typedef struct {
	SV *handle;

	SV *init_ref;
	SV *close_ref;
	SV *sort_ref;
	SV *search_ref;
	SV *fetch_ref;
	SV *present_ref;
	SV *esrequest_ref;
	SV *delete_ref;
	SV *scan_ref;
} Zfront_handle;

SV *init_ref = NULL;
SV *close_ref = NULL;
SV *sort_ref = NULL;
SV *search_ref = NULL;
SV *fetch_ref = NULL;
SV *present_ref = NULL;
SV *esrequest_ref = NULL;
SV *delete_ref = NULL;
SV *scan_ref = NULL;
int MAX_OID = 15;


Z_GenericRecord *read_grs1(char *str, ODR o)
{
	int type, ivalue;
	char line[512], *buf, *ptr, *original;
	char value[512];
 	Z_GenericRecord *r = 0;

	original = str;
	for (;;)
	{
		Z_TaggedElement *t;
		Z_ElementData *c;
	
		ptr = strchr(str, '\n');
		if (!ptr) {
			return r;
		}
		strncpy(line, str, ptr - str);
		line[ptr - str] = 0;
		buf = line;
		str = ptr + 1;
		while (*buf && isspace(*buf))
			buf++;
		if (*buf == '}') {
			memmove(original, str, strlen(str));
			return r;
		}
		if (sscanf(buf, "(%d,%[^)])", &type, value) != 2)
		{
			yaz_log(LOG_WARN, "Bad data in '%s'", buf);
			return 0;
		}
		if (!type && *value == '0')
			return r;
		if (!(buf = strchr(buf, ')')))
			return 0;
		buf++;
		while (*buf && isspace(*buf))
			buf++;
		if (!*buf)
			return 0;
		if (!r)
		{
			r = (Z_GenericRecord *)odr_malloc(o, sizeof(*r));
			r->elements = (Z_TaggedElement **)
			odr_malloc(o, sizeof(Z_TaggedElement*) * GRS_MAX_FIELDS);
			r->num_elements = 0;
		}
		r->elements[r->num_elements] = t = (Z_TaggedElement *) odr_malloc(o, sizeof(Z_TaggedElement));
		t->tagType = (int *)odr_malloc(o, sizeof(int));
		*t->tagType = type;
		t->tagValue = (Z_StringOrNumeric *)
			odr_malloc(o, sizeof(Z_StringOrNumeric));
		if ((ivalue = atoi(value)))
		{
			t->tagValue->which = Z_StringOrNumeric_numeric;
			t->tagValue->u.numeric = (int *)odr_malloc(o, sizeof(int));
			*t->tagValue->u.numeric = ivalue;
		}
		else
		{
			t->tagValue->which = Z_StringOrNumeric_string;
			t->tagValue->u.string = (char *)odr_malloc(o, strlen(value)+1);
			strcpy(t->tagValue->u.string, value);
		}
		t->tagOccurrence = 0;
		t->metaData = 0;
		t->appliedVariant = 0;
		t->content = c = (Z_ElementData *)odr_malloc(o, sizeof(Z_ElementData));
		if (*buf == '{')
		{
			c->which = Z_ElementData_subtree;
			c->u.subtree = read_grs1(str, o);
		}
		else
		{
			c->which = Z_ElementData_string;
/*			buf[strlen(buf)-1] = '\0';*/
			buf[strlen(buf)] = '\0';
			c->u.string = odr_strdup(o, buf);
		}
		r->num_elements++;
	}
}




static void oid2str(Odr_oid *o, WRBUF buf)
{
    for (; *o >= 0; o++) {
	char ibuf[16];
	sprintf(ibuf, "%d", *o);
	wrbuf_puts(buf, ibuf);
	if (o[1] > 0)
	    wrbuf_putc(buf, '.');
    }
}


static int rpn2pquery(Z_RPNStructure *s, WRBUF buf)
{
    switch (s->which) {
	case Z_RPNStructure_simple: {
	    Z_Operand *o = s->u.simple;

	    switch (o->which) {
		case Z_Operand_APT: {
		    Z_AttributesPlusTerm *at = o->u.attributesPlusTerm;

		    if (at->attributes) {
			int i;
			char ibuf[16];

			for (i = 0; i < at->attributes->num_attributes; i++) {
			    wrbuf_puts(buf, "@attr ");
			    if (at->attributes->attributes[i]->attributeSet) {
				oid2str(at->attributes->attributes[i]->attributeSet, buf);
				wrbuf_putc(buf, ' ');
			    }
			    sprintf(ibuf, "%d=", *at->attributes->attributes[i]->attributeType);
			    assert(at->attributes->attributes[i]->which == Z_AttributeValue_numeric);
			    wrbuf_puts(buf, ibuf);
			    sprintf(ibuf, "%d ", *at->attributes->attributes[i]->value.numeric);
			    wrbuf_puts(buf, ibuf);
			}
		    }
		    switch (at->term->which) {
			case Z_Term_general: {
			    wrbuf_putc(buf, '"');
			    wrbuf_write(buf, (char*) at->term->u.general->buf, at->term->u.general->len);
			    wrbuf_puts(buf, "\" ");
			    break;
			}
			default: abort();
		    }
		    break;
		}
		default: abort();
	    }
	    break;
	}
	case Z_RPNStructure_complex: {
	    Z_Complex *c = s->u.complex;

	    switch (c->roperator->which) {
		case Z_Operator_and: wrbuf_puts(buf, "@and "); break;
		case Z_Operator_or: wrbuf_puts(buf, "@or "); break;
		case Z_Operator_and_not: wrbuf_puts(buf, "@not "); break;
		case Z_Operator_prox: abort();
		default: abort();
	    }
	    if (!rpn2pquery(c->s1, buf))
		return 0;
	    if (!rpn2pquery(c->s2, buf))
		return 0;
	    break;
	}
	default: abort();
    }
    return 1;
}


WRBUF zquery2pquery(Z_Query *q)
{
    WRBUF buf = wrbuf_alloc();

    if (q->which != Z_Query_type_1 && q->which != Z_Query_type_101) 
	return 0;
    if (q->u.type_1->attributeSetId) {
	/* Output attribute set ID */
	wrbuf_puts(buf, "@attrset ");
	oid2str(q->u.type_1->attributeSetId, buf);
	wrbuf_putc(buf, ' ');
    }
    return rpn2pquery(q->u.type_1->RPNStructure, buf) ? buf : 0;
}


int bend_sort(void *handle, bend_sort_rr *rr)
{
	HV *href;
	AV *aref;
	SV **temp;
	SV *err_code;
	SV *err_str;
	SV *status;
	STRLEN len;
	char *ptr;
	char *ODR_err_str;
	char **input_setnames;
	Zfront_handle *zhandle = (Zfront_handle *)handle;
	int i;
	
	dSP;
	ENTER;
	SAVETMPS;
	
	aref = newAV();
	input_setnames = rr->input_setnames;
	for (i = 0; i < rr->num_input_setnames; i++)
	{
		av_push(aref, newSVpv(*input_setnames++, 0));
	}
	href = newHV();
	hv_store(href, "INPUT", 5, newRV( (SV*) aref), 0);
	hv_store(href, "OUTPUT", 6, newSVpv(rr->output_setname, 0), 0);
	hv_store(href, "HANDLE", 6, zhandle->handle, 0);
	hv_store(href, "STATUS", 6, newSViv(0), 0);

	PUSHMARK(sp);

	XPUSHs(sv_2mortal(newRV( (SV*) href)));

	PUTBACK;

	perl_call_sv(sort_ref, G_SCALAR | G_DISCARD);

	SPAGAIN;

	temp = hv_fetch(href, "ERR_CODE", 8, 1);
	err_code = newSVsv(*temp);

	temp = hv_fetch(href, "ERR_STR", 7, 1);
	err_str = newSVsv(*temp);

	temp = hv_fetch(href, "STATUS", 6, 1);
	status = newSVsv(*temp);


	

	PUTBACK;
	FREETMPS;
	LEAVE;

	hv_undef(href),
	av_undef(aref);
	rr->errcode = SvIV(err_code);
	rr->sort_status = SvIV(status);
	ptr = SvPV(err_str, len);
	ODR_err_str = (char *)odr_malloc(rr->stream, len + 1);
	strcpy(ODR_err_str, ptr);
	rr->errstring = ODR_err_str;

	sv_free(err_code);
	sv_free(err_str);
	sv_free(status);
	
	return 0;
}


int bend_search(void *handle, bend_search_rr *rr)
{
	HV *href;
	AV *aref;
	SV **temp;
	SV *hits;
	SV *err_code;
	SV *err_str;
	char *ODR_errstr;
	STRLEN len;
	int i;
	char **basenames;
	int n;
	WRBUF query;
	char *ptr;
	SV *point;
	SV *ODR_point;
	Zfront_handle *zhandle = (Zfront_handle *)handle;

	dSP;
	ENTER;
	SAVETMPS;

	aref = newAV();
	basenames = rr->basenames;
	for (i = 0; i < rr->num_bases; i++)
	{
		av_push(aref, newSVpv(*basenames++, 0));
	}
	href = newHV();		
	hv_store(href, "SETNAME", 7, newSVpv(rr->setname, 0), 0);
	hv_store(href, "REPL_SET", 8, newSViv(rr->replace_set), 0);
	hv_store(href, "ERR_CODE", 8, newSViv(0), 0);
	hv_store(href, "ERR_STR", 7, newSVpv("", 0), 0);
	hv_store(href, "HITS", 4, newSViv(0), 0);
	hv_store(href, "DATABASES", 9, newRV( (SV*) aref), 0);
	hv_store(href, "HANDLE", 6, zhandle->handle, 0);
	hv_store(href, "PID", 3, newSViv(getpid()), 0);
	query = zquery2pquery(rr->query);
	if (query)
	{
		hv_store(href, "QUERY", 5, newSVpv((char *)query->buf, query->pos), 0);
	}
	else
	{	
		rr->errcode = 108;
	}
	PUSHMARK(sp);
	
	XPUSHs(sv_2mortal(newRV( (SV*) href)));
	
	PUTBACK;

	n = perl_call_sv(search_ref, G_SCALAR | G_DISCARD);

	SPAGAIN;

	temp = hv_fetch(href, "HITS", 4, 1);
	hits = newSVsv(*temp);

	temp = hv_fetch(href, "ERR_CODE", 8, 1);
	err_code = newSVsv(*temp);

	temp = hv_fetch(href, "ERR_STR", 7, 1);
	err_str = newSVsv(*temp);

	temp = hv_fetch(href, "HANDLE", 6, 1);
	point = newSVsv(*temp);

	PUTBACK;
	FREETMPS;
	LEAVE;
	
	hv_undef(href);
	av_undef(aref);
	rr->hits = SvIV(hits);
	rr->errcode = SvIV(err_code);
	ptr = SvPV(err_str, len);
	ODR_errstr = (char *)odr_malloc(rr->stream, len + 1);
	strcpy(ODR_errstr, ptr);
	rr->errstring = ODR_errstr;
/*	ODR_point = (SV *)odr_malloc(rr->stream, sizeof(*point));
	memcpy(ODR_point, point, sizeof(*point));
	zhandle->handle = ODR_point;*/
	zhandle->handle = point;
	handle = zhandle;
	sv_free(hits);
	sv_free(err_code);
	sv_free(err_str);
	sv_free( (SV*) aref);
	sv_free( (SV*) href);
	/*sv_free(point);*/
	wrbuf_free(query, 1);
	return 0;
}


WRBUF oid2dotted(int *oid)
{

	WRBUF buf = wrbuf_alloc();
	int dot = 0;

	for (; *oid != -1 ; oid++)
	{
		char ibuf[16];
		if (dot)
		{
			wrbuf_putc(buf, '.');
		}
		else
		{
			dot = 1;
		}
		sprintf(ibuf, "%d", *oid);
		wrbuf_puts(buf, ibuf);
	}
	return buf;
}
		

int dotted2oid(char *dotted, int *buffer)
{
        int *oid;
        char ibuf[16];
        char *ptr;
        int n = 0;

        ptr = ibuf;
        oid = buffer;
        while (*dotted)
        {
                if (*dotted == '.')
                {
                        n++;
			if (n == MAX_OID)  /* Terminate if more than MAX_OID entries */
			{
				*oid = -1;
				return -1;
			}
                        *ptr = 0;
                        sscanf(ibuf, "%d", oid++);
                        ptr = ibuf;
                        dotted++;

                }
                else
                {
                        *ptr++ = *dotted++;
                }
        }
        if (n < MAX_OID)
	{
		*ptr = 0;
        	sscanf(ibuf, "%d", oid++);
	}
        *oid = -1;
	return 0;
}


int bend_fetch(void *handle, bend_fetch_rr *rr)
{
	HV *href;
	SV **temp;
	SV *basename;
	SV *record;
	SV *last;
	SV *err_code;
	SV *err_string;
	SV *sur_flag;
	SV *point;
	SV *rep_form;
	char *ptr;
	char *ODR_record;
	char *ODR_basename;
	char *ODR_errstr;
	int *ODR_oid_buf;
	oident *oid;
	WRBUF oid_dotted;
	Zfront_handle *zhandle = (Zfront_handle *)handle;

	Z_RecordComposition *composition;
	Z_ElementSetNames *simple;
	STRLEN length;

	dSP;
	ENTER;
	SAVETMPS;

	rr->errcode = 0;
	href = newHV();
	hv_store(href, "SETNAME", 7, newSVpv(rr->setname, 0), 0);
	temp = hv_store(href, "OFFSET", 6, newSViv(rr->number), 0);
	oid_dotted = oid2dotted(rr->request_format_raw);
	hv_store(href, "REQ_FORM", 8, newSVpv((char *)oid_dotted->buf, oid_dotted->pos), 0);
	hv_store(href, "REP_FORM", 8, newSVpv((char *)oid_dotted->buf, oid_dotted->pos), 0);
	hv_store(href, "BASENAME", 8, newSVpv("", 0), 0);
	hv_store(href, "RECORD", 6, newSVpv("", 0), 0);
	hv_store(href, "LAST", 4, newSViv(0), 0);
	hv_store(href, "ERR_CODE", 8, newSViv(0), 0);
	hv_store(href, "ERR_STR", 7, newSVpv("", 0), 0);
	hv_store(href, "SUR_FLAG", 8, newSViv(0), 0);
	hv_store(href, "HANDLE", 6, zhandle->handle, 0);
	hv_store(href, "PID", 3, newSViv(getpid()), 0);
	if (rr->comp)
	{
		composition = rr->comp;
		if (composition->which == Z_RecordComp_simple)
		{
			simple = composition->u.simple;
			if (simple->which == Z_ElementSetNames_generic)
			{
				hv_store(href, "COMP", 4, newSVpv(simple->u.generic, 0), 0);
			} 
			else
			{
				rr->errcode = 26;
			}
		}
		else
		{
			rr->errcode = 26;
		}
	}

	PUSHMARK(sp);

	XPUSHs(sv_2mortal(newRV( (SV*) href)));

	PUTBACK;
	
	perl_call_sv(fetch_ref, G_SCALAR | G_DISCARD);

	SPAGAIN;

	temp = hv_fetch(href, "BASENAME", 8, 1);
	basename = newSVsv(*temp);

	temp = hv_fetch(href, "RECORD", 6, 1);
	record = newSVsv(*temp);

	temp = hv_fetch(href, "LAST", 4, 1);
	last = newSVsv(*temp);

	temp = hv_fetch(href, "ERR_CODE", 8, 1);
	err_code = newSVsv(*temp);

	temp = hv_fetch(href, "ERR_STR", 7, 1),
	err_string = newSVsv(*temp);

	temp = hv_fetch(href, "SUR_FLAG", 8, 1);
	sur_flag = newSVsv(*temp);

	temp = hv_fetch(href, "REP_FORM", 8, 1);
	rep_form = newSVsv(*temp);

	temp = hv_fetch(href, "HANDLE", 6, 1);
	point = newSVsv(*temp);

	PUTBACK;
	FREETMPS;
	LEAVE;

	hv_undef(href);
	
	ptr = SvPV(basename, length);
	ODR_basename = (char *)odr_malloc(rr->stream, length + 1);
	strcpy(ODR_basename, ptr);
	rr->basename = ODR_basename;

	ptr = SvPV(rep_form, length);
	ODR_oid_buf = (int *)odr_malloc(rr->stream, (MAX_OID + 1) * sizeof(int));
	if (dotted2oid(ptr, ODR_oid_buf) == -1)		/* Maximum number of OID elements exceeded */
	{
		printf("Net::Z3950::SimpleServer: WARNING: OID structure too long, max length is %d\n", MAX_OID);
	}
	rr->output_format_raw = ODR_oid_buf;	
	
	ptr = SvPV(record, length);
	oid = oid_getentbyoid(ODR_oid_buf);
	if (oid->value == VAL_GRS1)		/* Treat GRS-1 records separately */
	{
		rr->record = (char *) read_grs1(ptr, rr->stream);
		rr->len = -1;
	}
	else
	{
		ODR_record = (char *)odr_malloc(rr->stream, length + 1);
		strcpy(ODR_record, ptr);
		rr->record = ODR_record;
		rr->len = length;
	}
	zhandle->handle = point;
	handle = zhandle;
	rr->last_in_set = SvIV(last);
	
	if (!(rr->errcode))
	{
		rr->errcode = SvIV(err_code);
		ptr = SvPV(err_string, length);
		ODR_errstr = (char *)odr_malloc(rr->stream, length + 1);
		strcpy(ODR_errstr, ptr);
		rr->errstring = ODR_errstr;
	}
	rr->surrogate_flag = SvIV(sur_flag);

	wrbuf_free(oid_dotted, 1);
	sv_free((SV*) href);
	sv_free(basename);
	sv_free(record);
	sv_free(last);
	sv_free(err_string);
	sv_free(err_code),
	sv_free(sur_flag);
	sv_free(rep_form);
	
	return 0;
}


int bend_present(void *handle, bend_present_rr *rr)
{

	HV *href;
	SV **temp;
	SV *err_code;
	SV *err_string;
	SV *hits;
	SV *point;
	STRLEN len;
	Z_RecordComposition *composition;
	Z_ElementSetNames *simple;
	char *ODR_errstr;
	char *ptr;
	Zfront_handle *zhandle = (Zfront_handle *)handle;

/*	WRBUF oid_dotted; */

	dSP;
	ENTER;
	SAVETMPS;

	href = newHV();
        hv_store(href, "HANDLE", 6, zhandle->handle, 0);
	hv_store(href, "ERR_CODE", 8, newSViv(0), 0);
	hv_store(href, "ERR_STR", 7, newSVpv("", 0), 0);
	hv_store(href, "START", 5, newSViv(rr->start), 0);
	hv_store(href, "SETNAME", 7, newSVpv(rr->setname, 0), 0);
	hv_store(href, "NUMBER", 6, newSViv(rr->number), 0);
	/*oid_dotted = oid2dotted(rr->request_format_raw);
        hv_store(href, "REQ_FORM", 8, newSVpv((char *)oid_dotted->buf, oid_dotted->pos), 0);*/
	hv_store(href, "HITS", 4, newSViv(0), 0);
	hv_store(href, "PID", 3, newSViv(getpid()), 0);
	if (rr->comp)
	{
		composition = rr->comp;
		if (composition->which == Z_RecordComp_simple)
		{
			simple = composition->u.simple;
			if (simple->which == Z_ElementSetNames_generic)
			{
				hv_store(href, "COMP", 4, newSVpv(simple->u.generic, 0), 0);
			} 
			else
			{
				rr->errcode = 26;
				return 0;
			}
		}
		else
		{
			rr->errcode = 26;
			return 0;
		}
	}

	PUSHMARK(sp);
	
	XPUSHs(sv_2mortal(newRV( (SV*) href)));
	
	PUTBACK;
	
	perl_call_sv(present_ref, G_SCALAR | G_DISCARD);
	
	SPAGAIN;

	temp = hv_fetch(href, "ERR_CODE", 8, 1);
	err_code = newSVsv(*temp);

	temp = hv_fetch(href, "ERR_STR", 7, 1);
	err_string = newSVsv(*temp);

	temp = hv_fetch(href, "HITS", 4, 1);
	hits = newSVsv(*temp);

	temp = hv_fetch(href, "HANDLE", 6, 1);
	point = newSVsv(*temp);

	PUTBACK;
	FREETMPS;
	LEAVE;
	
	hv_undef(href);
	rr->errcode = SvIV(err_code);
	rr->hits = SvIV(hits);

	ptr = SvPV(err_string, len);
	ODR_errstr = (char *)odr_malloc(rr->stream, len + 1);
	strcpy(ODR_errstr, ptr);
	rr->errstring = ODR_errstr;
/*	wrbuf_free(oid_dotted, 1);*/
	zhandle->handle = point;
	handle = zhandle;
	sv_free(err_code);
	sv_free(err_string);
	sv_free(hits);
	sv_free( (SV*) href);

	return 0;
}


int bend_esrequest(void *handle, bend_esrequest_rr *rr)
{
	perl_call_sv(esrequest_ref, G_VOID | G_DISCARD | G_NOARGS);
	return 0;
}


int bend_delete(void *handle, bend_delete_rr *rr)
{
	perl_call_sv(delete_ref, G_VOID | G_DISCARD | G_NOARGS);
	return 0;
}


int bend_scan(void *handle, bend_scan_rr *rr)
{
	perl_call_sv(scan_ref, G_VOID | G_DISCARD | G_NOARGS);
	return 0;
}


bend_initresult *bend_init(bend_initrequest *q)
{
	bend_initresult *r = (bend_initresult *) odr_malloc (q->stream, sizeof(*r));
	HV *href;
	SV **temp;
	SV *name;
	SV *ver;
	SV *err_str;
	SV *status;
	Zfront_handle *zhandle =  (Zfront_handle *) xmalloc (sizeof(*zhandle));
	STRLEN len;
	int n;
	SV *handle;
	/*char *name_ptr;
	char *ver_ptr;*/
	char *ptr;

	dSP;
	ENTER;
	SAVETMPS;

	/*q->bend_sort = bend_sort;*/
	if (search_ref)
	{
		q->bend_search = bend_search;
	}
	if (present_ref)
	{
		q->bend_present = bend_present;
	}
	/*q->bend_esrequest = bend_esrequest;*/
	/*q->bend_delete = bend_delete;*/
	if (fetch_ref)
	{
		q->bend_fetch = bend_fetch;
	}
	/*q->bend_scan = bend_scan;*/
       	href = newHV();	
	hv_store(href, "IMP_NAME", 8, newSVpv("", 0), 0);
	hv_store(href, "IMP_VER", 7, newSVpv("", 0), 0);
	hv_store(href, "ERR_CODE", 8, newSViv(0), 0);
	hv_store(href, "PEER_NAME", 9, newSVpv(q->peer_name, 0), 0);
	hv_store(href, "HANDLE", 6, newSVsv(&sv_undef), 0);
	hv_store(href, "PID", 3, newSViv(getpid()), 0);

	PUSHMARK(sp);	

	XPUSHs(sv_2mortal(newRV( (SV*) href)));

	PUTBACK;

	if (init_ref != NULL)
	{
		perl_call_sv(init_ref, G_SCALAR | G_DISCARD);
	}

	SPAGAIN;

	temp = hv_fetch(href, "IMP_NAME", 8, 1);
	name = newSVsv(*temp);

	temp = hv_fetch(href, "IMP_VER", 7, 1);
	ver = newSVsv(*temp);

	temp = hv_fetch(href, "ERR_CODE", 8, 1);
	status = newSVsv(*temp);

	temp = hv_fetch(href, "HANDLE", 6, 1);
	handle= newSVsv(*temp);

	hv_undef(href);
	PUTBACK;
	FREETMPS;
	LEAVE;
	zhandle->handle = handle;
	r->errcode = SvIV(status);
	r->handle = zhandle;
	ptr = SvPV(name, len);
	q->implementation_name = (char *)xmalloc(len + 1);
	strcpy(q->implementation_name, ptr);
/*	q->implementation_name = SvPV(name, len);*/
	ptr = SvPV(ver, len);
	q->implementation_version = (char *)xmalloc(len + 1);
	strcpy(q->implementation_version, ptr);
	
	return r;
}


void bend_close(void *handle)
{
	HV *href;
	Zfront_handle *zhandle = (Zfront_handle *)handle;
	SV **temp;

	dSP;
	ENTER;
	SAVETMPS;

	if (close_ref == NULL)
	{
		return;
	}

	href = newHV();
	hv_store(href, "HANDLE", 6, zhandle->handle, 0);

	PUSHMARK(sp);

	XPUSHs(sv_2mortal(newRV((SV *)href)));

	PUTBACK;
	
	perl_call_sv(close_ref, G_SCALAR | G_DISCARD);
	
	SPAGAIN;

	PUTBACK;
	FREETMPS;
	LEAVE;

	xfree(handle);
	
	return;
}


MODULE = Net::Z3950::SimpleServer	PACKAGE = Net::Z3950::SimpleServer

void
set_init_handler(arg)
		SV *arg
	CODE:
		init_ref = newSVsv(arg);
		

void
set_close_handler(arg)
		SV *arg
	CODE:
		close_ref = newSVsv(arg);


void
set_sort_handler(arg)
		SV *arg
	CODE:
		sort_ref = newSVsv(arg);

void
set_search_handler(arg)
		SV *arg
	CODE:
		search_ref = newSVsv(arg);


void
set_fetch_handler(arg)
		SV *arg
	CODE:
		fetch_ref = newSVsv(arg);


void
set_present_handler(arg)
		SV *arg
	CODE:
		present_ref = newSVsv(arg);


void
set_esrequest_handler(arg)
		SV *arg
	CODE:
		esrequest_ref = newSVsv(arg);


void
set_delete_handler(arg)
		SV *arg
	CODE:
		delete_ref = newSVsv(arg);


void
set_scan_handler(arg)
		SV *arg
	CODE:
		scan_ref = newSVsv(arg);


int
start_server(...)
	PREINIT:
		char **argv;
		char **argv_buf;
		char *ptr;
		int i;
		STRLEN len;
	CODE:
		argv_buf = (char **)xmalloc((items + 1) * sizeof(char *));
		argv = argv_buf;
		for (i = 0; i < items; i++)
		{
			ptr = SvPV(ST(i), len);
			*argv_buf = (char *)xmalloc(len + 1);
			strcpy(*argv_buf++, ptr); 
		}
		*argv_buf = NULL;
		
		RETVAL = statserv_main(items, argv, bend_init, bend_close);
	OUTPUT:
		RETVAL 
